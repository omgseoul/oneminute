import assert from 'node:assert/strict';
import {createBedsHandler,dateRange,selectBooking,selectMessage} from '../../supabase/functions/beds24/handler.mjs';
const p='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002',id='00000000-0000-0000-0000-000000000003';
let calls=[],outboxStatus=null,responseMode='ok',notify=false;
const res=v=>new Response(JSON.stringify(v),{headers:{'Content-Type':'application/json'}});
const fetcher=async(url,options={})=>{const b=options.body?JSON.parse(options.body):{},a=b.p_action;calls.push({url,a,body:b});
 if(url.includes('/rpc/online_owner')){if(a==='auth'){if(b.p_token!==token)return new Response(JSON.stringify({code:'P0001',message:'관리자'}),{status:400});return res({property_id:p,actor:'owner:test'});}if(a==='prepare_send'){if(outboxStatus)return res({ok:true,skip:true,status:outboxStatus});outboxStatus='sending';return res({ok:true});}return res({ok:true});}
 if(url.includes('/rpc/online_internal')){if(a==='credentials')return res({beds_property_id:100,secret:{token:'secret-access',refreshToken:'secret-refresh',expiresAt:Date.now()+9999999}});if(a==='finish_send')outboxStatus=b.p_data.status;if(a==='push_pending')return res([]);if(a==='webhook'){if(b.p_data.key!=='a'.repeat(64))return new Response(JSON.stringify({code:'P0001',message:'invalid_webhook'}),{status:400});notify=true;}return res({ok:true});}
 if(url.includes('/bookings/messages')&&options.method==='POST'){if(responseMode==='timeout')throw Error('timeout');if(responseMode==='reject')return res([{success:false}]);return res([{success:true,new:{id:500}}]);}
 if(url.includes('/bookings/messages'))return res({data:[],pages:{nextPageExists:false}});
 if(url.includes('/bookings?'))return res({data:[{id:10,propertyId:100,firstName:'G'}],pages:{nextPageExists:false}});
 throw Error('Unexpected '+url);
};
const env=n=>({SUPABASE_URL:'https://test.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'service'})[n];
const handler=createBedsHandler({env,fetcher,waitUntil:()=>{}});
const request=(action,data={},t=token)=>handler(new Request('https://test.supabase.co/functions/v1/beds24',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,data,access_token:t})}));
assert.throws(()=>dateRange({from:'2026-02-30',to:'2026-03-01',basis:'arrival'}));assert.throws(()=>dateRange({from:'2026-01-01',to:'2026-12-01',basis:'arrival'}));
assert(!('creditCardNumber' in selectBooking({id:1,creditCardNumber:'do not retain'})));assert(!('attachment' in selectMessage({id:1,attachment:'huge'})));
let r=await request('send',{booking_id:10,id,body:'Hi'},p);assert.equal(r.status,400);assert(!calls.some(c=>c.url.startsWith('https://beds24.com')),'auth before outbound access');calls=[];
r=await request('send',{booking_id:10,id,body:'Hi'});assert.equal((await r.json()).status,'sent');await request('send',{booking_id:10,id,body:'Hi'});assert.equal(calls.filter(c=>c.url.endsWith('/bookings/messages')&&Array.isArray(c.body)).length,1,'no duplicate OTA send');
outboxStatus=null;responseMode='timeout';r=await request('send',{booking_id:10,id,body:'Hi'});assert.equal((await r.json()).status,'uncertain');
outboxStatus=null;responseMode='reject';r=await request('send',{booking_id:10,id,body:'Hi'});assert.equal((await r.json()).status,'failed');
r=await handler(new Request(`https://test.supabase.co/functions/v1/beds24/webhook?property=${p}&key=${'b'.repeat(64)}`,{method:'POST',body:JSON.stringify({booking:{id:10}})}));assert.equal(r.status,400);assert(!notify);
r=await handler(new Request('https://test.supabase.co/functions/v1/beds24',{method:'POST',headers:{Origin:'https://evil.test'},body:'{}'}));assert.equal(r.status,403);
console.log('online edge: auth first, range validation, minimal data storage, duplicate prevention and ambiguous send handling passed');
