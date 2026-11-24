import assert from 'node:assert/strict';
import {createBedsHandler} from '../../supabase/functions/beds24/handler.mjs';
const token='00000000-0000-0000-0000-000000000001',property='00000000-0000-0000-0000-000000000002';
let calls=[],mismatch=false,empty=false,conflict=false,source='',unitId=1,infoCode='LOCK_PIN',foreign=false,inventoryError=false;
const handler=createBedsHandler({env:k=>({SUPABASE_URL:'https://fixture',SUPABASE_SERVICE_ROLE_KEY:'service'})[k],fetcher:async(url,o={})=>{
 const b=o.body?JSON.parse(o.body):{};calls.push({url,b});
 if(url.endsWith('/online_owner')){assert.equal(b.p_data.request_action,'booking_data');assert.equal(b.p_data.property_id,property);if(b.p_token!==token)return Response.json({code:'P0001',message:'권한 없음'},{status:403});return Response.json({property_id:property});}
 if(url.endsWith('/online_internal')){assert.equal(b.p_property,property);if(b.p_action==='credentials')return Response.json({beds_property_id:100,password_source:source,secret:{token:'secret',refreshToken:'refresh',expiresAt:Date.now()+900000}});if(b.p_action==='bookings')return Response.json({ok:true});throw Error('Unexpected internal action');}
 if(url.endsWith('/online_sync_control'))return Response.json({skip:false});
 if(url.includes('/bookings?')){assert.equal(new URL(url).searchParams.get('includeInfoItems'),'true');return Response.json({data:[{id:10,propertyId:mismatch?200:100,roomId:20,unitId,price:128000,...(empty?{}:{apiReference:'5228222557',phone:'+82 2 1234',mobile:'+82 10 1234',email:'not-exposed@example.test',infoItems:[{code:infoCode,text:'0473',bookingId:foreign?11:10},...(conflict?[{code:infoCode,text:'9999',bookingId:10}]:[])]})}]});}
 if(url.includes('/properties?')){if(inventoryError&&url.includes('includeUnitDetails'))return Response.json({}, {status:403});return Response.json({data:[{id:100,currency:'KRW',roomTypes:[{id:20,units:[{id:1,name:'201',name2:'0123'}]}]}]});}
 throw Error('Unexpected request '+url);
}});
const req=key=>handler(new Request('https://fixture/beds24',{method:'POST',body:JSON.stringify({action:'booking_detail',access_token:key,data:{property_id:property,booking_id:10}})}));
let r=await req(property);assert.equal(r.status,400);assert(!calls.some(x=>x.url.includes('beds24.com')),'authorization precedes provider lookup');
calls=[];r=await req(token);assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');assert.deepEqual((await r.json()).detail,{id:10,reference:'5228222557',phone:'+82 2 1234',mobile:'+82 10 1234',password:'0473',price:128000,currency:'KRW'});
let saved=calls.find(x=>x.b.p_action==='bookings').b.p_data.items[0];for(const field of ['infoItems','phone','mobile','email','password'])assert(!Object.hasOwn(saved,field),field+' never cached');assert.equal(saved.price,128000);
assert(!calls.some(x=>x.url.includes('includeUnitDetails')),'booking PIN does not require inventory');
empty=true;calls=[];assert.deepEqual((await (await req(token)).json()).detail,{id:10,price:128000,currency:'KRW'});
empty=false;unitId=null;inventoryError=true;assert.equal((await (await req(token)).json()).detail.password,'0473','PIN remains visible without unit assignment or inventory rights');
source='info:DOOR_PIN';infoCode='DOOR_PIN';assert.equal((await (await req(token)).json()).detail.password,'0473','configured info source supported');
foreign=true;assert.equal((await (await req(token)).json()).detail.password,undefined,'foreign booking item ignored');foreign=false;
conflict=true;r=await req(token);let d=(await r.json()).detail;assert(!d.password);assert(d.warning,'conflicting codes are not guessed');conflict=false;
source='unit:name2';unitId=1;inventoryError=false;assert.equal((await (await req(token)).json()).detail.password,'0123','configured unit PIN retains exact unit matching');
source='';infoCode='LOCK_PIN';mismatch=true;calls=[];assert.equal((await req(token)).status,400);assert(!calls.some(x=>x.b.p_action==='bookings'),'cross-property result rejected before saving');
console.log('Booking details: live price, isolated contacts/PIN, configured sources, missing inventory, conflict and authorization passed');
