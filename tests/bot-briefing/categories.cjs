const {setup,id}=require('./setup.cjs'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{const db=await setup();try{
 for(const file of ['briefing_delivery','briefing_shared_picker','briefing_test_delivery','briefing_owner_delivery']){
  if(file==='briefing_shared_picker')await db.exec("create function omg_private.target_work_state(uuid) returns text language sql as $$select 'off'::text$$");
  await db.exec(fs.readFileSync('supabase/setup/'+file+'.sql','utf8'));
 }
 await db.exec("create function omg_private.pin_delivery_state(uuid,bigint) returns jsonb language sql as $$select '{\"active\":true,\"state\":\"scheduled\",\"configured\":true}'::jsonb$$");
 await db.exec(fs.readFileSync('supabase/setup/briefing_categories.sql','utf8'));
 const p=id(1),other=id(2),owner=id(3),token=id(4),cleaner=id(5),multi=id(6);
 await db.query("insert into properties(id,name,management_number,timezone)values($1,'Nest',1,'Asia/Seoul'),($2,'Other',2,'Asia/Seoul')",[p,other]);
 await db.query("insert into owners(id,property_id,display_name)values($1,$2,'Manager')",[owner,p]);
 await db.query("insert into owner_sessions(owner_id,property_id,login_token_hash,token_expires_at)values($1,$2,omg_private.token_hash($3),'infinity')",[owner,p,token]);
 await db.query("insert into employees(id,property_id,display_name,duty_roles)values($1,$2,'Cleaner','{cleaning}'),($3,$2,'Multi','{reservation,onsite}')",[cleaner,p,multi]);
 const call=async(action,data={},prop=p)=>(await db.query('select public.bot_briefing_settings($1,$2,$3,$4) v',[token,prop,action,JSON.stringify(data)])).rows[0].v;
 const worker=async(action,data={})=>(await db.query('select public.bot_briefing_worker($1,$2) v',[action,JSON.stringify(data)])).rows[0].v;
 let cfg=(await call('get')).settings;
 const save={enabled:true,start_kind:'time',end_kind:'time',start_time:'19:00',end_time:'09:00',prompt:'운영 이슈',notify_kind:'checkin',notify_targets:['reservation','onsite','cleaning'],categories:cfg.categories};
 await call('save',save);
 await assert.rejects(()=>call('save',{...save,categories:{...cfg.categories,cleaning:{enabled:true,targets:[id(999)]}}}),/권한/);
 await assert.rejects(()=>call('get',{},other),/권한/);
 await db.query("insert into omg_private.online_bookings(property_id,id,guest_name,room_name,arrival,departure,status,channel,data)values($1,100,'Checkin Guest','401',(now() at time zone 'Asia/Seoul')::date,(now() at time zone 'Asia/Seoul')::date+2,'confirmed','Booking.com','{}')",[p]);
 const preview=await call('preview',save);await call('run',{id:preview.run.id});assert.equal((await worker('claim')).skip,true,'empty conversations need no AI');await worker('pushes');
 const bodies=(await db.query('select d.employee_id,d.owner_id,m.message from omg_private.briefing_deliveries d join property_messages m on m.id=d.message_ids[1] where d.run_id=$1',[preview.run.id])).rows;
 assert.equal(bodies.length,3,'one delivery per person even with multiple roles');
 const clean=bodies.find(x=>x.employee_id===cleaner).message;assert.match(clean,/■ 청소/);assert(!/예약관리|현장관리|체크인 명단|Checkin Guest/.test(clean));
 const multiple=bodies.find(x=>x.employee_id===multi).message;assert.match(multiple,/예약관리/);assert.match(multiple,/현장관리/);assert.match(multiple,/Checkin Guest/);assert(!multiple.includes('■ 청소'));
 assert.match(bodies.find(x=>x.owner_id===owner).message,/401 · Checkin Guest.*Booking.com.*비번 설정 \/ 발송 예정/);
 // Current category permissions are rechecked before an automatic delivery is released.
 await db.query("insert into omg_private.briefing_runs(id,property_id,mode,status,period_start,period_end,timezone,settings,finished_at,issues) values($1,$2,'auto','completed',now()-interval '3 hours',now()-interval '1 hour','Asia/Seoul',$3,now(),'[{\"category\":\"cleaning\",\"issue\":\"linen\",\"action\":\"replace\",\"status\":\"unresolved\"}]')",[id(30),p,JSON.stringify({...save,notify_kind:'time',notify_time:'00:00'})]);
 await db.query('select omg_private.briefing_enqueue_delivery(r) from omg_private.briefing_runs r where id=$1',[id(30)]);
 await db.query("update omg_private.briefing_deliveries set due_at=now()-interval '1 minute' where run_id=$1",[id(30)]);
 await call('save',{...save,categories:{...cfg.categories,cleaning:{enabled:false,targets:['manager','cleaning']}}});await worker('pushes');
 assert.equal((await db.query('select cardinality(message_ids) n from omg_private.briefing_deliveries where run_id=$1 and employee_id=$2',[id(30),cleaner])).rows[0].n,0,'disabled category is not delivered');
 await db.exec('set role anon');await assert.rejects(()=>db.query("select omg_private.briefing_render($1,'[]','{checkin}',current_date)",[p]),/permission/);await db.exec('reset role');
 console.log('Briefing categories: server filtering, multi-role dedup, zero-AI roster, tenant auth, disabled category recheck passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
