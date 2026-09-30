import test from 'node:test';
import assert from 'node:assert/strict';
import {Webhook} from 'svix';
import {createGuestEmailHandler,emailPayload,replyText,replyAlias} from '../../functions/guest-email/handler.mjs';
const id='00000000-0000-4000-8000-000000000001',alias=id.replaceAll('-','');
const secret='whsec_'+Buffer.from('test-webhook-secret-32-bytes-long!').toString('base64');
const vars={SUPABASE_URL:'https://database.test',SUPABASE_SERVICE_ROLE_KEY:'service-test',RESEND_API_KEY:'test-key',RESEND_WEBHOOK_SECRET:secret,GUEST_EMAIL_WORKER_SECRET:'worker-test',PUSH_ADMIN_SECRET:'push-test'};
const job={id,lease:id,payload:{alias,to:'guest@example.com',name:'One Minute',body:'바나나 <img src=x>',slug:id}};
const email={id,from:'Guest <guest@example.com>',to:[`reply-${alias}@reply.omgworks24.com`],text:'답장입니다',authentication:{dmarc:'pass'},headers:{},attachments:[]};
function setup(options={}){
 const calls=[];const handle=createGuestEmailHandler({env:k=>vars[k],wait:async()=>{},
 verifyWebhook:(raw,headers,key)=>{new Webhook(key).verify(raw,headers);return JSON.parse(raw);},
 fetcher:async(url,init={})=>{
  const body=typeof init.body==='string'?JSON.parse(init.body):init.body;calls.push({url,init,body});
  if(url.endsWith('/claim_guest_emails'))return Response.json([structuredClone(job)]);
  if(url.endsWith('/finish_guest_email'))return new Response(null,{status:204});
  if(url==='https://api.resend.com/emails')return Response.json(options.sendFails?{error:'rate_limit'}:{id:'sent-id'},{status:options.sendFails?429:200});
  if(url.includes('/emails/receiving/'))return Response.json({...email,...options.email});
  if(url.endsWith('/resolve_guest_email'))return Response.json(options.denied?null:{room_id:id,property_id:id});
  if(url.endsWith('/receive_guest_email'))return Response.json({ok:true,event_id:id,duplicate:!!options.duplicate});
  if(url.includes('/dispatch-notification/'))return Response.json({ok:true},{status:options.pushFails?503:200});
  throw Error('unexpected call: '+url);
 }});
 const webhook=async(tampered=false,old=false)=>{
  const raw=JSON.stringify({type:'email.received',data:{email_id:id}}),date=new Date(Date.now()-(old?3600000:0));
  const sig=new Webhook(secret).sign('msg_test',date,raw);
  return handle(new Request('https://edge.test/guest-email/webhook',{method:'POST',headers:{'svix-id':'msg_test','svix-timestamp':String(Math.floor(+date/1000)),'svix-signature':sig},body:tampered?raw+' ':raw}));
 };
 return {calls,handle,webhook,dispatch:(key='worker-test')=>handle(new Request('https://edge.test/guest-email/dispatch',{method:'POST',headers:{'x-worker-secret':key}}))};
}
test('From and Reply-To use exactly the same conversation address; HTML is escaped',()=>{
 const p=emailPayload(job);assert.equal(p.from,`One Minute <reply-${alias}@reply.omgworks24.com>`);assert.equal(p.reply_to,`reply-${alias}@reply.omgworks24.com`);
 assert(p.html.includes('&lt;img src=x&gt;'));assert(!p.html.includes('<img src=x>'));assert(p.text.includes(job.payload.body));
});
test('opaque route accepts exactly one conversation; never guesses among tenants',()=>{
 assert.equal(replyAlias(email.to),id);assert.equal(replyAlias([...email.to,'reply-'+('a'.repeat(32))+'@reply.omgworks24.com']),null);assert.equal(replyAlias(['reply-'+alias+'@evil.example']),null);
});
test('signed reply enters existing guest chat and dispatches its event',async()=>{
 const s=setup();assert.equal((await s.webhook()).status,200);const receive=s.calls.find(c=>c.url.endsWith('/receive_guest_email'));
 assert.equal(receive.body.p_body,'답장입니다');assert.equal(receive.body.p_sender,'guest@example.com');assert.equal(receive.body.p_alias,id);assert.equal(receive.body.p_provider,id);
 assert(s.calls.some(c=>c.url.includes('/dispatch-notification/')));
});
test('tampered and expired webhook signatures have no network side effects',async()=>{
 for(const args of [[true,false],[false,true]]){const s=setup();assert.equal((await s.webhook(...args)).status,401);assert.equal(s.calls.length,0);}
});
test('spoofed sender auth, unrelated guest and autoresponder never create messages',async()=>{
 for(const options of [{email:{authentication:{dmarc:'fail',dkim:'pass'}}},{email:{authentication:{}}},{denied:true},{email:{headers:{'Auto-Submitted':'auto-replied'}}}]){
  const s=setup(options);assert.equal((await s.webhook()).status,200);assert(!s.calls.some(c=>c.url.endsWith('/receive_guest_email')));
 }
});
test('worker endpoint refuses public dispatch',async()=>{const s=setup();assert.equal((await s.dispatch('wrong')).status,401);assert.equal(s.calls.length,0);});
test('send retries use identical content and the same provider idempotency key',async()=>{
 const s=setup();await s.dispatch();await s.dispatch();const sends=s.calls.filter(c=>c.url==='https://api.resend.com/emails');assert.deepEqual(sends[0].body,sends[1].body);
 assert.equal(sends[0].init.headers['Idempotency-Key'],'guest-message/'+id);assert.equal(sends[1].init.headers['Idempotency-Key'],'guest-message/'+id);
});
test('provider failure records a retry instead of reporting sent',async()=>{
 const s=setup({sendFails:true});assert.equal((await (await s.dispatch()).json()).sent,0);const f=s.calls.find(c=>c.url.endsWith('/finish_guest_email'));assert.equal(f.body.p_error,'provider_429');assert.equal(f.body.p_provider,undefined);
});
test('push failure returns retryable status, duplicate receipt can retry notification',async()=>{
 const s=setup({duplicate:true,pushFails:true});assert.equal((await s.webhook()).status,503);assert(s.calls.some(c=>c.url.includes('/dispatch-notification/')));
});
test('quoted original is trimmed but unrecognized email is preserved',()=>{
 assert.equal(replyText({text:'감사합니다\n\nOn Wed, Host wrote:\nold text'}),'감사합니다');
 assert.equal(replyText({text:'First line\nSecond line'}),'First line\nSecond line');
 assert.equal(replyText({html:'<script>bad()</script><p>안녕 &amp; hi</p>'}),'안녕 & hi');
});
test('photo reply fetches only provider attachment URL and stores in resolved property/room',async()=>{
 const calls=[],png=new Uint8Array([137,80,78,71,13,10,26,10,0,0,0,0]);
 const handler=createGuestEmailHandler({env:k=>vars[k],wait:async()=>{},verifyWebhook:()=>({type:'email.received',data:{email_id:id}}),fetcher:async(url,init={})=>{
  const body=typeof init.body==='string'?JSON.parse(init.body):init.body;calls.push({url,body,init});
  if(url.includes('?html_format=cid'))return Response.json({...email,text:'사진입니다',attachments:[{id,content_type:'image/png',size:png.length}]});
  if(url.includes('/attachments/'))return Response.json({download_url:'https://inbound-cdn.resend.com/photo'});
  if(url==='https://inbound-cdn.resend.com/photo')return new Response(png);
  if(url.endsWith('/resolve_guest_email'))return Response.json({room_id:id,property_id:id});
  if(url.includes('/storage/'))return Response.json({ok:true});
  if(url.endsWith('/receive_guest_email'))return Response.json({ok:true});
  throw Error('unexpected');
 }});
 const r=await handler(new Request('https://edge.test/webhook',{method:'POST',body:'{}'}));assert.equal(r.status,200);
 const received=calls.find(c=>c.url.endsWith('/receive_guest_email'));assert.deepEqual(received.body.p_assets,[{path:`${id}/${id}/email/${id}/${id}`,mime:'image/png'}]);
 assert.equal(calls.find(c=>c.url.startsWith('https://inbound-cdn')).init.redirect,'error');
});
