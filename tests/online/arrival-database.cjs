const fs=require('node:fs'),assert=require('node:assert/strict');
module.exports=async({db,owner,internal,p1,p2,t1,t2,id})=>{
 const sql=fs.readFileSync('supabase/setup/beds24_arrival_estimates.sql','utf8');await db.exec(sql);await db.exec(sql);
 const day='2027-03-01',room=31000,hash='a'.repeat(64),otherHash='b'.repeat(64);
 await db.query("update omg_private.online_connections set properties=$2 where property_id=$1",[p1,JSON.stringify([{id:100,name:'Synthetic',roomTypes:[{id:room,qty:3,units:[{id:1,name:'401'},{id:2,name:'402'},{id:3,name:'403'}]}]}])]);
 const book=(bid,unit,arrival,departure,status='confirmed')=>({id:bid,propertyId:100,roomId:room,unitId:unit,firstName:'Synthetic arrival',arrival,departure,status});
 await internal('bookings',{items:[book(31001,1,'2027-02-28',day),book(31002,2,'2027-02-28',day),book(31003,3,'2027-02-28',day),book(31011,1,day,'2027-03-03'),book(31012,2,day,'2027-03-03'),book(31013,3,day,'2027-03-03','cancelled')]});
 const ctl=async(action,data={},token=t1)=>(await db.query('select public.online_arrivals($1,$2,$3) v',[token,action,JSON.stringify({property_id:p1,day,...data})])).rows[0].v;
 await assert.rejects(()=>ctl('read',{},t2),/권한/);await assert.rejects(()=>ctl('read',{},id(999999)),/관리자/);
 let v=await ctl('read');assert(v.items.every(i=>i.state==='unknown'),'no-checkin is not asserted before a successful arrival sync');
 let run=await ctl('start');assert(!(run.skip));assert((await ctl('start')).skip,'concurrent run deduplicated');await ctl('synced',{run_id:run.id});v=await ctl('read');assert.equal(v.items.find(i=>i.room_key.endsWith(':3')).state,'no_checkin');assert.equal((await ctl('candidates',{run_id:run.id})).items.length,2);
 await db.query("update omg_private.ai_provider set enabled=true,vault_id=gen_random_uuid()");await db.query("update omg_private.ai_wallets set enabled=true,balance_micro=1000000,monthly_limit_micro=1000000 where property_id=$1",[p1]);
 const before=(await db.query('select balance_micro from omg_private.ai_wallets where property_id=$1',[p1])).rows[0].balance_micro;
 await ctl('prepare',{run_id:run.id,input_bytes:1000,items:[{booking_id:31011,hash},{booking_id:31012,hash}]});
 const result={run_id:run.id,input_tokens:100,output_tokens:20,results:[{booking_id:31011,hash,time_from:'18:00',time_to:null,evidence_kind:'message',evidence_ref:'message:1'},{booking_id:31012,hash,time_from:null,time_to:null}]};await ctl('finish',result);const after=(await db.query('select balance_micro from omg_private.ai_wallets where property_id=$1',[p1])).rows[0].balance_micro;assert(after<before);await ctl('finish',result);assert.equal((await db.query('select balance_micro from omg_private.ai_wallets where property_id=$1',[p1])).rows[0].balance_micro,after,'duplicate finish never charges twice');
 v=await ctl('read');assert.equal(v.items.find(i=>i.booking_id===31011).time_from,'18:00');assert.equal(v.items.find(i=>i.booking_id===31012).state,'unknown');
 await db.query("update omg_private.online_arrival_runs set checked_at=now()-interval '1 minute' where property_id=$1",[p1]);run=await ctl('start');await ctl('synced',{run_id:run.id});await ctl('prepare',{run_id:run.id,input_bytes:1000,items:[{booking_id:31011,hash:otherHash}]});await ctl('finish',{run_id:run.id,results:[{booking_id:31011,hash:otherHash,time_from:null,time_to:null}]});assert.equal((await ctl('read')).items.find(i=>i.booking_id===31011).time_from,'18:00','later unknown extraction retains confirmed time durably');
 // A pending allocation must not turn an empty assigned room into a false no-checkin.
 await internal('bookings',{items:[book(31014,0,day,'2027-03-03')]});assert.equal((await ctl('read')).items.find(i=>i.room_key.endsWith(':3')).state,'unknown');
 await internal('bookings',{items:[book(31014,0,day,'2027-03-03','cancelled'),book(31011,2,day,'2027-03-03')]});v=await ctl('read');assert(v.items.filter(i=>i.state==='known').length===0,'reassigned or ambiguous room never inherits another unit cached ETA');
 const grants=(await db.query("select has_function_privilege('anon','public.online_arrivals(uuid,text,jsonb)','EXECUTE') a,has_function_privilege('authenticated','public.online_arrivals(uuid,text,jsonb)','EXECUTE') b")).rows[0];assert(!grants.a&&!grants.b);
 assert((await ctl('prepare',{run_id:run.id,input_bytes:1,items:[{booking_id:999999,hash}]})).skip,'completed jobs reject late writes');
 console.log('Arrival DB: owner/branch authorization, complete-sync states, unique unit matching, persistent times, stale/ambiguous assignments and idempotent AI budgets passed');
};
