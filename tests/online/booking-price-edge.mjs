import assert from 'node:assert/strict';
import {createBedsHandler,selectBooking} from '../../supabase/functions/beds24/handler.mjs';
const property='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002';
for(const price of [null,undefined,'',false,'1200',-1,NaN,Infinity])assert.equal(selectBooking({price}).price,null);
assert.equal(selectBooking({price:0}).price,0);assert.equal(selectBooking({price:123.45}).price,123.45);
assert(!('stripeToken' in selectBooking({price:1,stripeToken:'private'})));
async function run({currency='KRW',price=128000,missing=false,currencyError=false}={}){
 const saved=[],requests=[];const handler=createBedsHandler({env:n=>({SUPABASE_URL:'https://fixture.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'fixture'})[n],waitUntil:()=>{},fetcher:async(url,init={})=>{
  const body=init.body?JSON.parse(init.body):{};requests.push(url);
  if(url.endsWith('/rpc/online_owner'))return Response.json(body.p_action==='auth'?{property_id:property,actor:'owner'}:{ok:true,bookings:[]});
  if(url.endsWith('/rpc/online_sync_control'))return Response.json(body.p_action==='begin'?{lease:'fixture'}:{});
  if(url.endsWith('/rpc/online_internal')){
   if(body.p_action==='credentials')return Response.json({beds_property_id:100,secret:{token:'fixture',refreshToken:'fixture',expiresAt:Date.now()+3600000}});
   if(body.p_action==='bookings')saved.push(...body.p_data.items);
   return Response.json(body.p_action==='push_pending'?[]:{ok:true});
  }
  if(url.includes('/bookings?'))return Response.json({data:[{id:10,propertyId:100,status:'confirmed',...(missing?{}:{price}),creditCardNumber:'do not retain'}],pages:{nextPageExists:false}});
  if(url.includes('/properties?')){assert.equal(new URL(url).searchParams.get('id'),'100');if(currencyError)return Response.json({}, {status:403});return Response.json({data:[{id:100,currency,notes:'private'}],pages:{nextPageExists:false}});}
  throw Error('Unexpected '+url);
 }});
 const response=await handler(new Request('https://fixture.supabase.co/functions/v1/beds24',{method:'POST',body:JSON.stringify({action:'sync_booking_data',access_token:token,data:{property_id:property,from:'2026-11-14',to:'2026-11-15'}})}));
 assert.equal(response.status,200);assert.equal((await response.json()).cached,false);assert.equal(saved.length,2);
 assert(saved.every(b=>b.price===(missing?null:price)&&b.currency===(missing||currencyError?null:currency)));
 assert(!JSON.stringify(saved).includes('do not retain'));assert(!JSON.stringify(saved).includes('private'));
 assert.equal(requests.filter(u=>u.includes('/properties?')).length,missing?0:1,'Currency fetched only once for both booking pages');
}
await run();await run({currency:'USD',price:128.75});await run({price:0});await run({missing:true});await run({currencyError:true});
console.log('Booking price: provider totals, explicit zero, absent financial access, safe currency lookup and allowlist passed');
