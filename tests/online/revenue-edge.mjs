import test from 'node:test';import assert from 'node:assert/strict';
import {createBedsHandler,revenueImportRange} from '../../supabase/functions/beds24/handler.mjs';
const property='00000000-0000-0000-0000-000000000001',token='00000000-0000-0000-0000-000000000002';
async function run({kind='owner',from='2026-11-01',to='2026-11-30',skip=false,fail=false,foreign=false,unauthorized=false}={}){
 const saved=[],calls=[],finishes=[];let limited=false;
 const handler=createBedsHandler({env:n=>({SUPABASE_URL:'https://fixture.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'fixture'})[n],waitUntil:()=>{},fetcher:async(url,init={})=>{
  const body=init.body?JSON.parse(init.body):{};calls.push(url);
  if(url.endsWith('/rpc/online_owner'))return unauthorized?Response.json({code:'P0001',message:'권한이 없습니다.'},{status:400}):Response.json({property_id:property,actor:'owner',kind});
  if(url.endsWith('/rpc/online_sync_control')){
   if(body.p_action==='begin')return Response.json(skip?{skip:true,limited:true,retry_at:'2026-11-28T10:00:00Z'}:{lease:'fixture'});
   if(body.p_action==='cooldown')limited=true;
   if(body.p_action==='finish')finishes.push(body.p_data);
   return Response.json(limited?{skip:true,retry_at:'2026-11-28T10:00:00Z'}:{});
  }
  if(url.endsWith('/rpc/guest_can_access'))return Response.json(true);
  if(url.endsWith('/rpc/online_internal')){
   if(body.p_action==='credentials')return Response.json({beds_property_id:100,secret:{token:'fixture',refreshToken:'fixture',expiresAt:Date.now()+3600000}});
   if(body.p_action==='bookings')saved.push(...body.p_data.items);
   return Response.json(body.p_action==='push_pending'?[]:{ok:true});
  }
  if(url.includes('/bookings?')){const params=new URL(url).searchParams,page=Number(params.get('page'));if(fail&&page===2)return Response.json({}, {status:429,headers:{'retry-after':'60'}});return Response.json({data:[{id:(params.has('status')?100:0)+page,propertyId:foreign?999:100,price:100}],pages:{nextPageExists:page===1}});}
  if(url.includes('/properties?'))return Response.json({data:[{id:100,currency:'KRW'}],pages:{nextPageExists:false}});
  throw Error('Unexpected '+url);
 }});
 const response=await handler(new Request('https://fixture.supabase.co/functions/v1/beds24',{method:'POST',body:JSON.stringify({action:'sync_revenue',access_token:token,data:{property_id:property,from,to,basis:'staying'}})}));
 return {status:response.status,result:await response.json(),saved,calls,finishes};
}
test('reject annual/cross-month import before provider credentials and enforce owner authorization',async()=>{for(const args of [{from:'2026-01-01',to:'2026-12-31'},{from:'2026-10-31',to:'2026-11-01'},{kind:'staff'},{unauthorized:true}]){const r=await run(args);assert.equal(r.status,400);assert.equal(r.finishes.length,0);assert(!r.calls.some(u=>u.includes('beds24.com')||u.endsWith('/online_internal')));}assert.doesNotThrow(()=>revenueImportRange({from:'2024-02-01',to:'2024-02-29',basis:'booked'}));});
test('all normal and cancellation pages finish before declaring monthly import complete',async()=>{const r=await run();assert.equal(r.status,200);assert.equal(r.result.complete,true);assert.equal(r.result.cached,false);assert.equal(r.saved.length,4);assert.equal(r.calls.filter(u=>u.includes('/bookings?')).length,4);assert.equal(r.finishes[0].success,true);assert(!('bookings' in r.result));});
test('partial provider failure keeps saved page, does not mark coverage complete, exposes retry time',async()=>{const r=await run({fail:true});assert.equal(r.saved.length,1);assert.equal(r.result.complete,false);assert.equal(r.result.cached,true);assert.equal(r.finishes[0].success,false);assert.equal(r.result.retry_at,'2026-11-28T10:00:00Z');assert.match(r.result.warning,/요청 한도/);});
test('cached or throttled request is never presented as fresh completion',async()=>{const r=await run({skip:true});assert.equal(r.result.complete,false);assert.equal(r.saved.length,0);assert(!r.calls.some(u=>u.includes('beds24.com')));});
test('reject cross-property provider response without storing it',async()=>{const r=await run({foreign:true});assert.equal(r.result.complete,false);assert.equal(r.saved.length,0);assert.equal(r.finishes[0].success,false);});
