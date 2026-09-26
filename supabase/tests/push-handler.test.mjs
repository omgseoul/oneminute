import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { createNotificationHandler } from '../functions/dispatch-notification/handler.mjs';

const keys = await webcrypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' }, true, ['sign','verify']);
const pem = '-----BEGIN PRIVATE KEY-----\n' + Buffer.from(await webcrypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64') + '\n-----END PRIVATE KEY-----';
const id = '00000000-0000-4000-8000-000000000001';
const topic = 'property_123_employee_' + id;
function harness(options={}) {
 const config = { FCM_SERVICE_ACCOUNT:JSON.stringify({private_key:pem,client_email:'test@example.invalid',project_id:'guesthouse-manager-ajh'}),SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'test-only',PUSH_DELIVERY_ENABLED:'true',TELEGRAM_URGENT_SECRET:'test-webhook',PUSH_ADMIN_SECRET:'test-admin',...options.config };
 const calls=[],claims=new Map();let auth=true;
 const fetcher=async(url,init)=>{
  const body=url.endsWith('/token')?null:JSON.parse(init.body);calls.push({url,body});
  if(url.endsWith('/token'))return Response.json({access_token:'fake-token',expires_in:3600});
  if(url.includes('fcm.googleapis.com'))return Response.json({}, {status:options.failFcm?500:200});
  if(url.endsWith('get_message_push_dispatch_v2'))return Response.json(auth?{ok:true,message_id:id,recipient_topics:options.topics||[topic],message:'한'.repeat(2000),message_type:'attendance_warning',sender_label:'근태관리',priority:'normal'}:{ok:false,code:'invalid_session'});
  if(url.endsWith('claim_push_delivery')){if(claims.has(body.p_key))return Response.json({ok:true,claimed:false,status:claims.get(body.p_key)});claims.set(body.p_key,'sending');return Response.json({ok:true,claimed:true,lease_id:id});}
  if(url.endsWith('finish_push_delivery')){if(body.p_success)claims.set(body.p_key,'sent');else claims.delete(body.p_key);return Response.json({ok:true});}
  if(url.endsWith('get_guest_chat_dispatch'))return Response.json({ok:true,message_id:id,room_id:id,recipient_topics:[topic],message:'guest',priority:'urgent'});
  if(url.endsWith('finish_guest_chat_dispatch'))return Response.json(null);
  if(url.endsWith('save_telegram_urgent_message_service'))return Response.json({ok:true,message_id:id});
  throw Error('Unexpected network request');
 };
 const handle=createNotificationHandler({env:n=>config[n],fetcher,cryptoApi:webcrypto});
 const request=(body={access_token:id,message_id:id},path='',headers={})=>handle(new Request('https://example.invalid/functions/v1/dispatch-notification'+path,{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)}));
 return {request,calls,claims,revoke:()=>auth=false,config};
}
test('anonymous/malformed requests cannot reach FCM',async()=>{const h=harness();assert.equal((await h.request({message_id:id})).status,400);assert.equal(h.calls.length,0);});
test('expired session is rejected by database before FCM',async()=>{const h=harness();h.revoke();assert.equal((await h.request()).status,403);assert.equal(h.calls.length,1);});
test('production switch defaults to disabled until explicitly enabled',async()=>{const h=harness({config:{PUSH_DELIVERY_ENABLED:''}});assert.equal((await h.request()).status,503);assert(!h.calls.some(c=>c.url.includes('fcm.googleapis.com')));});
test('FCM receives original category/sender and bounded UTF-8 payload',async()=>{const h=harness();assert.equal((await h.request()).status,200);const sent=h.calls.find(c=>c.url.includes('fcm.googleapis.com')).body;assert.equal(sent.message.data.messageType,'attendance_warning');assert.equal(sent.message.data.senderLabel,'근태관리');assert(Buffer.byteLength(JSON.stringify(sent.message))<4096);});
test('successful delivery is not repeated',async()=>{const h=harness();await h.request();const result=await(await h.request()).json();assert.equal(result.duplicates,1);assert.equal(h.calls.filter(c=>c.url.includes('fcm.googleapis.com')).length,1);});
test('lease in progress is not falsely reported as sent',async()=>{const h=harness();h.claims.set(id+':'+topic,'sending');assert.equal((await h.request()).status,502);});
test('FCM rejection returns failure and allows explicit retry',async()=>{const h=harness({failFcm:true});assert.equal((await h.request()).status,502);assert.equal(h.claims.size,0);});
test('untrusted browser origin is rejected',async()=>{const h=harness();assert.equal((await h.request(undefined,'',{origin:'https://evil.invalid'})).status,403);assert.equal(h.calls.length,0);});
test('Telegram requires secret and stable external identifier',async()=>{const h=harness();assert.equal((await h.request({text:'!!hello'},'/telegram')).status,401);assert.equal((await h.request({text:'!!hello',property_id:'123'},'/telegram',{'x-webhook-secret':'test-webhook'})).status,400);});
test('Telegram saves inbox before transport and namespacing isolates properties',async()=>{const h=harness();assert.equal((await h.request({text:'!!hello',property_id:'123',update_id:42},'/telegram',{'x-webhook-secret':'test-webhook'})).status,200);const save=h.calls.findIndex(c=>c.url.endsWith('save_telegram_urgent_message_service'));const send=h.calls.findIndex(c=>c.url.includes('fcm.googleapis.com'));assert(save<send);assert.equal(h.calls[save].body.p_external_id,'property:123:42');assert.equal(h.calls[send].body.message.topic,'property_123_staff');});
test('validation never sends a real notification and requires admin secret',async()=>{const h=harness();assert.equal((await h.request({},'/validate')).status,401);assert.equal((await h.request({},'/validate',{'x-webhook-secret':'test-admin'})).status,200);assert.equal(h.calls.find(c=>c.url.includes('fcm.googleapis.com')).body.validate_only,true);assert.equal(h.claims.size,0);});
test('missing credentials cannot produce a false success',async()=>{const h=harness({config:{FCM_SERVICE_ACCOUNT:''}});assert.equal((await h.request()).status,503);});

test('guest chat dispatcher requires server secret and binds recipient identity',async()=>{const h=harness();assert.equal((await h.request({event_id:id},'/guest-chat')).status,401);assert.equal((await h.request({event_id:id},'/guest-chat',{'x-webhook-secret':'test-admin'})).status,200);const d=h.calls.find(c=>c.url.includes('fcm.googleapis.com')).body.message.data;assert.equal(d.recipientKey,'employee:'+id);assert.equal(d.roomId,id);assert.equal(d.messageType,'guest_chat');assert.equal(d.mode,'urgent');assert(h.calls.some(c=>c.url.endsWith('finish_guest_chat_dispatch')));});
