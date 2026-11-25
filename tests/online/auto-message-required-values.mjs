import assert from 'node:assert/strict';
import {createAutoMessages,renderAutoMessage} from '../../supabase/functions/beds24/auto-messages.mjs';
assert.throws(()=>renderAutoMessage('{{이름}} {{객실}} {{비밀번호}}',{'이름':' ','객실':null}),/이름, 객실, 비밀번호/);
for(const text of [undefined,'','{{unknown}}','{{}}','{{이름','이름}}'])assert.throws(()=>renderAutoMessage(text,{}));
for(const date of [undefined,'','not a date','2026-02-31'])assert.throws(()=>renderAutoMessage('{{체크인}}',{'체크인':date}),/체크인/);
assert.equal(renderAutoMessage('Hi {{이름}}',{'이름':'Guest'}),'Hi Guest','unused PIN/room are not required');
const booking={id:11,propertyId:100,roomId:200,unitId:1,status:'confirmed',firstName:'Guest',arrival:'2099-01-01',departure:'2099-01-02',infoItems:[{code:'LOCK_PIN',text:'0658'}]};
const inventory={data:[{id:100,roomTypes:[{id:200,units:[{id:1,name:'201'}]}]}]};
const job={id:'delivery',lease:'lease',property_id:'home',booking_id:11,timezone:'Asia/Seoul',rule:{enabled:true,messages:{common:'{{이름}} {{체크인}} {{체크아웃}} {{객실}} {{비밀번호}}'}}};
async function run(options={}){
 const actions=[],writes=[];let lookups=0;
 const worker=createAutoMessages({credentials:async()=>{if(options.credentialsError)throw options.credentialsError;return {beds_property_id:100,secret:{token:'secret'}};},saveBookings:async()=>{if(options.saveError)throw options.saveError;},messages:async()=>{},
  rpc:async(name,a)=>{actions.push(a);return a.p_action==='prepare'?(options.ready??{ok:true}):{ok:true};},
  api:async(path,h,body)=>{if(body){writes.push(body);return [{success:true}];}if(path.startsWith('/bookings?')){if(options.bookingError)throw options.bookingError;return options.bookingResult??{data:[{...booking,...options.booking}]};}lookups++;if(options.inventoryError)throw options.inventoryError;return options.inventory??inventory;}});
 await worker.process({...job,...options.job});return {actions,writes,lookups,last:actions.at(-1)?.p_data};
}
for(const options of [
 {booking:{firstName:'',lastName:''}},{booking:{arrival:null}},{booking:{departure:null}},
 {booking:{unitId:999}},{booking:{infoItems:[]}},{booking:{infoItems:[{code:'LOCK_PIN',text:'0658'},{code:'LOCK_PIN',text:'9999'}]}},
 {credentialsError:Error('secret 0658')},{bookingError:Error('secret 0658')},{saveError:Error('secret 0658')},{inventoryError:Error('secret 0658')},
 {bookingError:Object.assign(Error('권한 secret 0658'),{status:403})},{inventory:{data:[]}},{inventory:{}},{bookingResult:{data:[]}},{ready:{}},
 {job:{...job,rule:{enabled:true,messages:{}}}}
]){
 const r=await run(options);assert.equal(r.writes.length,0);assert.equal(r.last.status,'failed');assert(!/secret|0658/.test(r.last.error),'raw secrets never enter failure logs');
}
const valid=await run();assert.equal(valid.writes.length,1);assert.equal(valid.last.status,'sent');assert.match(valid.writes[0][0].message,/0658$/);
const nameOnly=await run({job:{...job,rule:{enabled:true,messages:{common:'Hi {{이름}}'}}},booking:{infoItems:[],unitId:null}});assert.equal(nameOnly.last.status,'sent');assert.equal(nameOnly.lookups,0);
const retry=await run({job:{...job,manual_retry:true},booking:{status:'cancelled'}});assert.equal(retry.last.status,'failed');assert.equal(retry.writes.length,0);
console.log('Required values: all five fields, combined missing reasons, malformed templates, lookup/auth/timeouts, secret redaction, used-field-only validation and manual retry guards passed');
