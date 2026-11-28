import assert from 'node:assert/strict';
import {isDirectBooking} from '../../supabase/functions/beds24/booking-source.mjs';
import {selectBooking} from '../../supabase/functions/beds24/handler.mjs';
import {createAutoMessages} from '../../supabase/functions/beds24/auto-messages.mjs';

for(const booking of [{apiSourceId:0},{apiSourceId:'0',apiSource:'custom'},{apiSource:'Direct'},
 {apiSource:' direct_booking '},{channel:'Manual'},{referer:'다이렉트 예약'},{apiSourceId:null,apiSource:'Direct'}])assert.equal(isDirectBooking(booking),true,JSON.stringify(booking));
for(const booking of [{},{apiSourceId:null},{apiSourceId:''},{apiSourceId:1,apiSource:'Booking Page'},
 {apiSourceId:19,apiSource:'Direct'},{apiSource:'Booking.com',referer:'Direct'},{apiSource:'Agoda'},{apiSource:'Hostelworld'}])assert.equal(isDirectBooking(booking),false,JSON.stringify(booking));
assert.equal(selectBooking({id:11,apiSourceId:0}).apiSourceId,0,'cache preserves authoritative zero source ID');
assert.equal(selectBooking({id:11}).apiSourceId,null,'missing source never coerced to zero');
const job={id:'job',lease:'lease',property_id:'prop',booking_id:11,timezone:'Asia/Seoul',rule:{enabled:true,pin_notice:true,messages:{common:'Hi {{이름}} {{비밀번호}}'}}};
for(const manual_retry of [false,true])for(const source of [{apiSource:'Direct'},{apiSourceId:0,apiSource:'Custom label'}]){
 const requests=[],controls=[],saved=[];
 const worker=createAutoMessages({credentials:async()=>({beds_property_id:100,secret:{token:'test'}}),messages:async()=>assert.fail('no message refresh'),
  saveBookings:async(p,c,b)=>saved.push(...b),rpc:async(name,args)=>{controls.push(args);return {ok:true,skip:true,excluded:true};},
  api:async(path,headers,body)=>{requests.push({path,body});assert.equal(body,undefined,'no guest POST');return {data:[{id:11,propertyId:100,status:'confirmed',...source}]};}});
 await worker.process({...job,manual_retry});
 assert.equal(requests.length,1,'exclude before room/PIN lookup');assert.equal(saved.length,1);
 assert.deepEqual(controls.map(x=>x.p_action),['exclude_direct'],'Direct must not become unsupported-channel failure, including retries');
}
let action;
const wrongProperty=createAutoMessages({credentials:async()=>({beds_property_id:100,secret:{token:'test'}}),messages:async()=>{},saveBookings:async()=>assert.fail('cross-property cache write'),
 rpc:async(name,args)=>{action=args;return {ok:true};},api:async()=>({data:[{id:11,propertyId:999,apiSourceId:0}]})});
await wrongProperty.process(job);assert.equal(action.p_action,'finish');assert.equal(action.p_data.status,'failed');assert.match(action.p_data.error,/지점/);
console.log('Direct worker: explicit source classification, zero-ID cache, early silent exclusion, retry exclusion and tenancy passed');
