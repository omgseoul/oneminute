import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {createGuestEmailHandler,emailPayload} from '../../functions/guest-email/handler.mjs';
const id='00000000-0000-4000-8000-000000000001',token='a'.repeat(64);
const vars={SUPABASE_URL:'https://database.test',SUPABASE_SERVICE_ROLE_KEY:'service-test',SMTP_HOST:'smtp.test',SMTP_USER:'user',SMTP_PASSWORD:'test',GUEST_EMAIL_WORKER_SECRET:'worker-test'};
const job={id,lease:id,payload:{to:'guest@example.com',name:'One Minute',body:'바나나 <img src=x>',link_token:token}};
function setup(options={}){
 const calls=[],sent=[];
 const handle=createGuestEmailHandler({env:k=>({...vars,...options.env})[k],cryptoApi:webcrypto,
 sendMail:async payload=>{sent.push(payload);if(options.smtpFails)throw Error('timeout');return {accepted:['guest@example.com']};},
 fetcher:async(url,init={})=>{
  const body=typeof init.body==='string'?JSON.parse(init.body):init.body;calls.push({url,init,body});
  if(url.endsWith('/claim_guest_emails'))return Response.json([structuredClone(job)]);
  if(url.endsWith('/finish_guest_email')||url.endsWith('/fail_guest_email'))return new Response(null,{status:204});
  if(url.endsWith('/open_guest_email'))return Response.json({ok:true,room_id:id,slug:id,guest_token:body.p_new_token,expires:Date.now()+3600000});
  throw Error('unexpected call');
 }});
 return {calls,sent,handle,dispatch:(key='worker-test')=>handle(new Request('https://edge.test/guest-email/dispatch',{method:'POST',headers:{'x-worker-secret':key}}))};
}
test('mail contains exact host answer and reply button to a secret room link; no inbound address',()=>{
 const p=emailPayload(job);assert.equal(p.from.address,'notifications@omgworks24.com');assert.equal(p.from.name,'One Minute');
 assert(p.html.includes('답변하기'));assert(p.html.includes('#reply='+token));assert(p.text.includes(job.payload.body));
 assert(p.html.includes('&lt;img src=x&gt;'));assert(!p.html.includes('<img src=x>'));
 assert.equal(p.reply_to,undefined);assert(!JSON.stringify(p).includes('reply.omgworks24.com'));
 assert(p.text.includes('이 이메일에 회신하지 말고 아래 링크를 눌러주세요.'));
 assert(p.html.indexOf('Please do not reply to this email.')<p.html.indexOf('<a href='));
});
test('dispatch uses SMTP without any Resend keys or API calls',async()=>{
 const s=setup();const r=await s.dispatch();assert.equal(r.status,200);assert.equal((await r.json()).sent,1);assert.equal(s.sent.length,1);assert.equal(s.sent[0].from.address,'notifications@omgworks24.com');
 assert(s.calls.every(c=>c.url.startsWith(vars.SUPABASE_URL)));
});
test('SMTP uncertainty is failed for review instead of automatically duplicated',async()=>{
 const s=setup({smtpFails:true});await s.dispatch();assert(s.calls.some(c=>c.url.endsWith('/fail_guest_email')));assert(!s.calls.some(c=>c.url.endsWith('/finish_guest_email')));
});
test('public callers cannot dispatch and old incoming webhook no longer exists',async()=>{
 const s=setup();assert.equal((await s.dispatch('wrong')).status,401);
 assert.equal((await s.handle(new Request('https://edge.test/guest-email/webhook',{method:'POST',body:'{}'}))).status,404);assert.equal(s.calls.length,0);
});
test('link exchange works independently of SMTP and creates server-chosen session',async()=>{
 const s=setup({env:{SMTP_HOST:undefined}});const r=await s.handle(new Request('https://edge.test/guest-email/open',{method:'POST',headers:{Origin:'https://omgworks24.com'},body:JSON.stringify({token,room_id:'forged',guest_token:'forged'})}));
 assert.equal(r.status,200);const v=await r.json();assert.equal(v.room_id,id);assert.notEqual(v.guest_token,'forged');assert.equal(s.calls[0].body.p_link,token);assert.equal(s.calls[0].body.room_id,undefined);
 assert.equal(r.headers.get('Access-Control-Allow-Origin'),'https://omgworks24.com');
});
test('malformed links and foreign origins are rejected before database access',async()=>{
 const s=setup();for(const [body,origin,status] of [[{token:'bad'},'https://omgworks24.com',400],[{token},'https://evil.test',403]]){
 const r=await s.handle(new Request('https://edge.test/open',{method:'POST',headers:{Origin:origin},body:JSON.stringify(body)}));assert.equal(r.status,status);
 }assert.equal(s.calls.length,0);
});
test('fresh browser uses returned original room and removes secret from URL',async()=>{
 const source=await readFile(new URL('../../../guest-email-link.js',import.meta.url),'utf8');const saved=new Map(),urls=[],requests=[];
 const context={window:{OMG_SUPABASE:{url:'https://database.test',publishableKey:'public'}},URLSearchParams,AbortSignal,
 location:{hash:'#reply='+token,pathname:'/guest-chat.html'},localStorage:{setItem:(k,v)=>saved.set(k,JSON.parse(v))},history:{replaceState:(_a,_b,url)=>urls.push(url)},
 fetch:async(url,init)=>{requests.push({url,init});return Response.json({ok:true,room_id:id,slug:id,guest_token:id,expires:Date.now()+3600000});}};
 vm.runInNewContext(source,context);await context.window.openGuestEmailLink();
 assert.equal(saved.get('omg_guest_'+id).room_id,id);assert.equal(urls[0],'/guest-chat.html?p='+id);assert(!requests[0].url.includes(token));assert.equal(JSON.parse(requests[0].init.body).token,token);
});
