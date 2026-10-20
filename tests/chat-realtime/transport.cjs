// Uses only a public API key. Random public test topic has no users or data;
// unknown private capability must be rejected. No accounts/sessions are created.
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const key='sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI';
const url='wss://rfcozgyvupvachhhblzn.supabase.co/realtime/v1/websocket?apikey='+key+'&vsn=1.0.0';
function probe(privateChannel){return new Promise((resolve,reject)=>{
 const topic='realtime:'+(privateChannel?'oms-live:':'oms-protocol-test:')+crypto.randomUUID(),ws=new WebSocket(url);let joined=false;
 const timer=setTimeout(()=>{ws.close();reject(Error('WebSocket probe timed out'));},15000);
 const finish=error=>{clearTimeout(timer);ws.close();error?reject(error):resolve();};
 ws.onopen=()=>ws.send(JSON.stringify({topic,event:'phx_join',ref:'1',join_ref:'1',payload:{config:{private:privateChannel,broadcast:{self:true,ack:true},presence:{enabled:false}}}}));
 ws.onerror=()=>finish(Error('WebSocket connection failed'));
 ws.onmessage=e=>{try{const m=JSON.parse(e.data);if(m.event==='phx_reply'&&m.ref==='1'){
  if(privateChannel){assert.equal(m.payload.status,'error','unknown capability rejected');return finish();}
  assert.equal(m.payload.status,'ok');joined=true;ws.send(JSON.stringify({topic,event:'broadcast',ref:'2',join_ref:'1',payload:{event:'protocol-check',type:'broadcast',payload:{fixture:true}}}));
 }else if(m.event==='broadcast'){assert(joined&&!privateChannel);assert.equal(m.payload.event,'protocol-check');assert.equal(m.payload.payload.fixture,true);finish();}}catch(error){finish(error);}};
 });}
(async()=>{await probe(false);await probe(true);console.log('PASS: actual Supabase WebSocket v1 handshake/broadcast and unauthorized private-channel denial');})().catch(e=>{console.error(e);process.exitCode=1;});
