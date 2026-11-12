import assert from 'node:assert/strict';
import {createBedsHandler,dateRange,selectBooking,selectMessage} from '../../supabase/functions/beds24/handler.mjs';
const p='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002',id='00000000-0000-0000-0000-000000000003';
let calls=[],outboxStatus=null,responseMode='ok',notify=false,hydrate=false,skipSync=false,limited=false,rateLimit=false,metadataCached=false;
const res=v=>new Response(JSON.stringify(v),{headers:{'Content-Type':'application/json'}});
const fetcher=async(url,options={})=>{const b=options.body?JSON.parse(options.body):{},a=b.p_action;calls.push({url,a,body:b});
 if(url.includes('/rpc/online_sync_control')){if(a==='begin')return res(skipSync?{skip:true}:{lease:id});if(a==='check')return res({skip:limited});if(a==='cooldown'){limited=true;return res({skip:true});}if(a==='metadata_needed')return res(metadataCached?[]:b.p_data.ids);return res({ok:true});}
 if(url.includes('/rpc/online_owner')){if(a==='auth'){if(b.p_token!==token)return new Response(JSON.stringify({code:'P0001',message:'관리자'}),{status:400});return res({property_id:b.p_data.property_id||p,actor:'owner:test'});}if(a==='prepare_send'){if(outboxStatus)return res({ok:true,skip:true,status:outboxStatus});outboxStatus='sending';return res({ok:true});}return res({ok:true});}
 if(url.includes('/rpc/online_internal')){if(a==='credentials')return res({beds_property_id:100,secret:{token:'secret-access',refreshToken:'secret-refresh',expiresAt:Date.now()+9999999}});if(a==='finish_send')outboxStatus=b.p_data.status;if(a==='push_pending')return res([]);if(a==='webhook'){if(b.p_data.key!=='a'.repeat(64))return new Response(JSON.stringify({code:'P0001',message:'invalid_webhook'}),{status:400});notify=true;}return res({ok:true});}
 if(url.includes('/bookings/messages')&&options.method==='POST'){if(responseMode==='timeout')throw Error('timeout');if(responseMode==='reject')return res([{success:false}]);return res([{success:true,new:{id:500}}]);}
 if(url.includes('/bookings/messages')&&rateLimit)return new Response('{}',{status:429,headers:{'x-five-min-limit-resets-in':'123'}});
 if(url.includes('/bookings/messages'))return res({data:hydrate?[{id:20,bookingId:10,propertyId:100,source:'guest',message:'hello'},{id:21,bookingId:11,propertyId:100,source:'guest',message:'cancel'}]:[],pages:{nextPageExists:false}});
 if(url.includes('/bookings?'))return res({data:hydrate?(url.includes('status=cancelled')?[{id:11,propertyId:100,status:'cancelled'}]:[{id:10,propertyId:100,status:'confirmed'}]):[{id:10,propertyId:100,firstName:'G'}],pages:{nextPageExists:false}});
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
calls=[];hydrate=true;r=await request('sync_messages',{property_id:id,statuses:['confirmed']});assert.equal(r.status,200);assert(calls.filter(c=>c.a==='auth').every(c=>c.body.p_data.property_id===id));assert(calls.filter(c=>c.a==='credentials'||c.a==='bookings'||c.a==='messages').every(c=>c.body.p_property===id),'all internal requests use authorized selected branch');assert(calls.some(c=>c.url.includes('/bookings?')&&new URL(c.url).searchParams.getAll('id').length===2),'hydrate booking status in batches');assert(calls.some(c=>c.url.includes('status=cancelled')));assert.deepEqual(calls.find(c=>c.a==='inbox').body.p_data.statuses,['confirmed']);
console.log('online edge: auth first, range validation, minimal data storage, duplicate prevention and ambiguous send handling passed');

calls=[];skipSync=true;r=await request('sync_messages');assert.equal(r.status,200);assert((await r.json()).cached);assert(!calls.some(c=>c.url.startsWith('https://beds24.com')),'sync lease/cooldown returns stored inbox without any Beds24 call');
skipSync=false;rateLimit=true;calls=[];r=await request('sync_messages');let value=await r.json();assert.equal(r.status,200);assert(value.cached&&value.warning.includes('저장된'));assert.equal(calls.find(c=>c.a==='cooldown').body.p_data.seconds,125,'provider reset header persisted with margin');
calls=[];r=await request('sync_messages');assert.equal(r.status,200);assert(!calls.some(c=>c.url.startsWith('https://beds24.com')),'other edge invocation obeys persisted cooldown');
limited=false;rateLimit=false;metadataCached=true;calls=[];r=await request('sync_messages');assert.equal(r.status,200);assert(!calls.some(c=>c.url.includes('/bookings?')),'recent booking metadata is not reloaded for the entire inbox');
console.log('online edge cache: duplicate sync suppression, 429 cache fallback, shared cooldown and metadata reuse passed');
