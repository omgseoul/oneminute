import assert from 'node:assert/strict';
import {createBedsHandler} from '../../supabase/functions/beds24/handler.mjs';
const prop='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002',sendId='00000000-0000-0000-0000-000000000003';
let calls=[],reject=false,auth=true,providerPosts=0;
const handler=createBedsHandler({env:k=>({SUPABASE_URL:'https://fixture',SUPABASE_SERVICE_ROLE_KEY:'service'})[k],fetcher:async(url,o={})=>{
 const d=o.body?JSON.parse(o.body):{};calls.push({url,d});
 if(url.endsWith('/online_owner')){if(!auth)return Response.json({code:'P0001',message:'권한 없음'},{status:403});return Response.json(d.p_action==='auth'?{property_id:prop,actor:'owner:test'}:{ok:true});}
 if(url.endsWith('/online_internal'))return Response.json(d.p_action==='credentials'?{beds_property_id:100,secret:{token:'x',refreshToken:'x',expiresAt:Date.now()+999999}}:{ok:true});
 if(url.endsWith('/online_sync_control'))return Response.json({skip:false});
 if(url.endsWith('/pin_delivery_internal'))return Response.json({ok:true,pin_delivery:{state:d.p_action==='external'?'sent':'unknown'}});
 if(url.includes('/bookings/messages')){if(o.method==='POST'){providerPosts++;return Response.json([{success:!reject}]);}return Response.json({data:[]});}
 if(url.includes('/bookings?'))return Response.json({data:[{id:10,propertyId:100,roomId:20,unitId:1,status:'confirmed',arrival:'2099-01-01',departure:'2099-01-03',infoItems:[{code:'LOCK_PIN',text:'0123'}]}]});
 if(url.includes('/properties?'))return Response.json({data:[{id:100,roomTypes:[{id:20,units:[{id:1,name:'401'}]}]}]});
 throw Error('Unexpected '+url);
}});
const call=async(action,data={})=>{const r=await handler(new Request('https://fixture/beds24',{method:'POST',body:JSON.stringify({access_token:token,action,data:{property_id:prop,booking_id:10,id:sendId,...data}})}));return {code:r.status,...await r.json()};};
auth=false;assert.equal((await call('pin_external')).code,400);assert(!calls.some(c=>c.url.includes('beds24.com')));auth=true;calls=[];
assert.equal((await call('pin_external',{expected_password:'0123'})).detail.pin_delivery.state,'sent');assert.equal(providerPosts,0,'external confirmation sends no message');assert.equal(calls.find(c=>c.d.p_action==='external').d.p_data.actor,'owner:test');
calls=[];assert.equal((await call('pin_external',{expected_password:'9999'})).code,400);assert(!calls.some(c=>c.d.p_action==='external'),'stale external confirmation cannot mark the new PIN delivered');
calls=[];assert.equal((await call('send',{pin_notice:true,body:'Code 9999'})).code,400);assert.equal(providerPosts,0,'stale PIN blocked before provider send');
calls=[];assert.equal((await call('send',{pin_notice:true,body:'Code 0123'})).status,'sent');assert.equal(providerPosts,1);assert.equal(calls.find(c=>c.d.p_action==='begin').d.p_data.pin,'0123');assert.equal(calls.find(c=>c.url.endsWith('/pin_delivery_internal')&&c.d.p_action==='finish').d.p_data.status,'sent');
calls=[];reject=true;assert.equal((await call('send',{pin_notice:true,body:'Code 0123'})).status,'failed');assert.equal(calls.find(c=>c.url.endsWith('/pin_delivery_internal')&&c.d.p_action==='finish').d.p_data.status,'failed');
console.log('Manual PIN delivery: auth before provider, external confirmation without sending, live PIN check and provider-result evidence passed');
