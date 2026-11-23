import assert from 'node:assert/strict';
import {createAutoMessages} from '../../supabase/functions/beds24/auto-messages.mjs';
import {createBriefingDispatch} from '../../supabase/functions/dispatch-briefing/handler.mjs';
let pending=[{id:'notice',message_id:'message'}],calls=[],allow=false,breakClaim=false;
const worker=createAutoMessages({rpc:async(name,b)=>{calls.push(b);if(b.p_action==='claim'){if(breakClaim)throw Error('worker unavailable');return {empty:true};}if(b.p_action==='pushes')return pending;if(b.p_action==='pushed')pending=[];},dispatchNotice:async mid=>{assert.equal(mid,'message');return allow;}});
await worker.drain();assert.equal(pending.length,1,'unconfirmed push remains pending');
allow=true;await worker.drain();assert.equal(pending.length,0,'only successful transport marks pushed');await worker.drain();assert.equal(calls.filter(c=>c.p_action==='pushed').length,1);
pending=[{id:'notice',message_id:'message'}];breakClaim=true;await assert.rejects(()=>worker.drain(),/worker unavailable/);assert.equal(pending.length,0,'notice delivery drains even when guest scheduling fails');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
let sent=[],done=new Set();const topic='property_1_owner_'+id(1);
const dispatch=createBriefingDispatch({env:n=>({SUPABASE_URL:'https://fixture',SUPABASE_SERVICE_ROLE_KEY:'service',PUSH_ADMIN_SECRET:'secret',PUSH_DELIVERY_ENABLED:'true',FCM_SERVICE_ACCOUNT:JSON.stringify({private_key:'AA==',client_email:'fixture@example.test',project_id:'guesthouse-manager-ajh'})}[n]),cryptoApi:{subtle:{importKey:async()=>({}),sign:async()=>new Uint8Array([1])}},fetcher:async(url,o={})=>{
 const b=o.headers?.['Content-Type']==='application/json'?JSON.parse(o.body):{};
 if(url.endsWith('/get_briefing_push_dispatch'))return Response.json({ok:true,message_id:id(90),message:'[자동메시지 미발송]\nNest · 객실 201\n예약 #100\n사유: 예약 접수 전에 발송시점이 지났습니다.',sender_label:'매니저 · 자동메시지',recipient_topics:[topic],recipient_modes:{[topic]:'normal'}});
 if(url.endsWith('/resolve_native_push_targets'))return Response.json([]);
 if(url.endsWith('/claim_push_delivery'))return Response.json(done.has(b.p_key)?{claimed:false,status:'sent'}:{claimed:true,lease_id:id(91)});
 if(url.endsWith('/finish_push_delivery')){done.add(b.p_key);return Response.json({ok:true});}
 if(url==='https://oauth2.googleapis.com/token')return Response.json({access_token:'token'});
 if(url.includes('fcm.googleapis.com')){sent.push(b.message);return Response.json({name:'ok'});}throw Error(url);
}});
const request=secret=>new Request('https://fixture/dispatch-briefing',{method:'POST',headers:{'x-webhook-secret':secret},body:JSON.stringify({message_id:id(90)})});
assert.equal((await dispatch(request('bad'))).status,401);assert.equal(sent.length,0);
assert.equal((await dispatch(request('secret'))).status,200);assert.equal(sent.length,1);assert.equal(sent[0].topic,topic);assert.match(sent[0].data.message,/객실 201/);assert.equal(sent[0].data.senderLabel,'매니저 · 자동메시지');assert.equal(sent[0].data.recipientKey,'owner:'+id(1));
await dispatch(request('secret'));assert.equal(sent.length,1,'existing push transport suppresses repeats');
console.log('Auto alert Edge: pending push retry, independent delivery, authorized owner bot payload and idempotent native transport passed');
