import assert from 'node:assert/strict';
import {createPinCalendar,isPinSentWrite} from '../../supabase/functions/beds24/pin-calendar.mjs';
import {createBedsHandler} from '../../supabase/functions/beds24/handler.mjs';
const job={property_id:'nest',booking_id:101,lease:'fixture'},payload=[{id:101,infoItems:[{code:'PINSENT',text:'OMS 비밀번호 발송 완료'}]}];
assert(isPinSentWrite('/bookings',payload));
for(const body of [[{...payload[0],status:'cancelled'}],[{id:101,infoItems:[{code:'LOCK_PIN',text:'1234'}]}],[...payload,...payload]])assert(!isPinSentWrite('/bookings',body));
assert(!isPinSentWrite('/bookings/messages',payload));
let marked=false,reject=false,wrongProperty=false,invalidEvidence=false,ambiguous=false,posts=0,finishes=[],saved=0;
const worker=createPinCalendar({credentials:async()=>({beds_property_id:10,secret:{token:'fixture'}}),saveBookings:async()=>saved++,
 rpc:async(name,b)=>{assert.equal(name,'pin_calendar_internal');if(b.p_action==='verify')return invalidEvidence?{skip:true}:{ok:true};if(b.p_action==='finish')finishes.push(b.p_data);},
 api:async(path,headers,body,options)=>{if(body){posts++;assert.equal(path,'/bookings');assert.deepEqual(body,payload);assert.deepEqual(options,{pinSent:true});if(reject)throw Error('token and private detail');marked=true;if(ambiguous)throw Error('response lost');return [{success:true}];}
  assert(path.includes('includeInfoItems=true'));return {data:[{id:101,propertyId:wrongProperty?99:10,infoItems:[{id:3,code:'OTHER',text:'untouched'},...(marked?[{id:4,code:'PINSENT',text:'already'}]:[])]}]};}});
await worker.process(job);assert.equal(posts,1);assert.equal(finishes.at(-1).status,'done');assert.equal(saved,1);
await worker.process(job);assert.equal(posts,1,'existing marker idempotent');
marked=false;reject=true;await worker.process(job);assert.equal(finishes.at(-1).status,'pending');assert(!JSON.stringify(finishes).includes('private detail'));
reject=false;ambiguous=true;await worker.process(job);assert.equal(finishes.at(-1).status,'pending');const before=posts;
await worker.process(job);assert.equal(posts,before,'read-after-ambiguous prevents duplicate info items');assert.equal(finishes.at(-1).status,'done');
wrongProperty=true;await worker.process(job);assert.equal(posts,before,'tenant mismatch cannot write');
wrongProperty=false;marked=false;invalidEvidence=true;await worker.process(job);assert.equal(posts,before,'changed PIN/stay cannot write');
console.log('Calendar outbox: narrow PINSENT capability, confirmed evidence, no duplicate markers, retry isolation, tenancy and sanitized failure passed');

const property='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002';
let authorized=false,followupCalls=[],providerCalls=[],work=[];
const handler=createBedsHandler({env:k=>({SUPABASE_URL:'https://fixture',SUPABASE_SERVICE_ROLE_KEY:'service'})[k],waitUntil:p=>work.push(p),fetcher:async(url,o={})=>{
 const d=o.body?JSON.parse(o.body):{};
 if(url.endsWith('/auto_message_followup')){followupCalls.push(d);if(!authorized)return Response.json({code:'P0001',message:'권한 없음'},{status:403});return Response.json(d.p_data.action==='state'?{ok:true,status:'open',property_id:property,booking_id:101,pin_notice:true,retry_count:0}:{ok:true,status:d.p_data.action});}
 if(url.endsWith('/online_internal'))return Response.json(d.p_action==='credentials'?{beds_property_id:10,secret:{token:'fixture',refreshToken:'fixture',expiresAt:Date.now()+999999}}:{ok:true});
 if(url.endsWith('/online_sync_control'))return Response.json({skip:false});
 if(url.endsWith('/pin_delivery_internal'))return Response.json({ok:true});
 if(url.endsWith('/pin_calendar_internal'))return Response.json({empty:true});
 providerCalls.push(url);
 if(url.includes('/bookings?'))return Response.json({data:[{id:101,propertyId:10,roomId:20,unitId:1,infoItems:[{code:'LOCK_PIN',text:'0123'}]}]});
 if(url.includes('/properties?'))return Response.json({data:[{id:10,roomTypes:[{id:20,units:[{id:1,name:'101'}]}]}]});
 throw Error('Unexpected request '+url);
}});
const act=async action=>{const r=await handler(new Request('https://fixture/beds24',{method:'POST',body:JSON.stringify({access_token:token,action:'auto_message_followup',data:{delivery_id:token,retry_count:0,action,pin:'INJECTED'}})}));return {status:r.status,body:await r.json()};};
assert.equal((await act('external')).status,400);assert.equal(providerCalls.length,0,'authorize recipient before reading booking');
authorized=true;assert.equal((await act('planned')).body.status,'planned');assert.equal(providerCalls.length,0,'planned performs no provider write/read');
assert.equal((await act('external')).body.status,'external');await Promise.all(work);
assert.equal(followupCalls.at(-1).p_data.pin,'0123','external delivery uses server-observed PIN, never client supplied PIN');
assert(!providerCalls.some(x=>x.includes('/bookings/messages')),'manual acknowledgement never sends a message');
console.log('Follow-up Edge: staff/owner service auth, planned without API calls, server-only PIN evidence and no guest send passed');
