const {setup,id}=require('./setup.cjs'),assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{
 const db=await setup({monthly:true}),p=id(1),other=id(2),owner=id(3),token=id(4),e1=id(5),e2=id(6),e3=id(7);
 await db.exec(fs.readFileSync('supabase/setup/briefing_delivery.sql','utf8'));
 const pickerSql=fs.readFileSync('supabase/migrations/20261109061321_admin_target_picker.sql','utf8');
 await db.exec(pickerSql.slice(pickerSql.indexOf('create or replace function omg_private.target_work_state'),pickerSql.indexOf('create or replace function public.list_target_people')));
 await db.exec(fs.readFileSync('supabase/setup/briefing_shared_picker.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/briefing_test_delivery.sql','utf8'));
 await db.query("insert into properties(id,name,management_number,timezone)values($1,'A',1,'Asia/Seoul'),($2,'B',2,'Asia/Seoul')",[p,other]);
 await db.query("insert into owners(id,property_id,display_name)values($1,$2,'owner');",[owner,p]);
 await db.query("insert into owner_sessions(owner_id,property_id,login_token_hash,token_expires_at)values($1,$2,omg_private.token_hash($3),'infinity')",[owner,p,token]);
 await db.query("insert into employees(id,property_id,display_name)values($1,$2,'a'),($3,$2,'b'),($4,$5,'other')",[e1,p,e2,e3,other]);
 const query=async(sql,args=[])=>(await db.query(sql,args)).rows[0];
 const call=async(action,data={},prop=p,t=token)=>(await query('select public.bot_briefing_settings($1,$2,$3,$4) v',[t,prop,action,JSON.stringify(data)])).v;
 const work=async(action,data={})=>(await query('select public.bot_briefing_worker($1,$2) v',[action,JSON.stringify(data)])).v;
 const roles=async(prop,e,rs,t=token)=>query("select employee_duty_roles($1,$2,'save',$3)",[t,prop,JSON.stringify({employee_id:e,roles:rs})]);
 await roles(p,e1,['reservation','onsite']);await roles(p,e2,['reservation']);
 await assert.rejects(()=>roles(other,e3,['reservation']),/권한/);await assert.rejects(()=>roles(p,e1,['owner']),/역할/);await assert.rejects(()=>call('get',{},other),/권한/);await assert.rejects(()=>call('get',{},p,id(999)),/권한/);
 await db.exec("set role anon");await assert.rejects(()=>work('claim'),/permission/);await db.exec('reset role');
 const cfg={enabled:true,start_kind:'time',end_kind:'time',start_time:'19:00',end_time:'09:00',prompt:'문제가 있는 대화만 요약'};
 await call('save',cfg);assert.equal((await call('get')).settings.start_time,'19:00:00');
 const per=async(c,now)=>(await query('select omg_private.briefing_period($1,$2,$3) v',[p,JSON.stringify(c),now])).v;
 assert.deepEqual(await per(cfg,'2026-11-19T10:00:00+09'),{start:'2026-11-18T10:00:00+00:00',end:'2026-11-19T00:00:00+00:00',timezone:'Asia/Seoul'});
 assert.equal((await per(cfg,'2026-11-19T08:00:00+09')).end,'2026-11-18T00:00:00+00:00');
 await assert.rejects(()=>call('save',{...cfg,end_time:'19:00'}),/다르게/);
 // Overlap: first worker leaves at 18; second at 19. Only 19 starts a period.
 for(const [n,e,ci,co] of [[11,e1,'2026-11-18T09:00+09','2026-11-18T18:00+09'],[12,e2,'2026-11-18T10:00+09','2026-11-18T19:00+09'],[13,e1,'2026-11-19T08:45+09',null],[14,e2,'2026-11-19T09:30+09',null]])await db.query("insert into work_sessions(id,employee_id,property_id,clock_in_at,clock_out_at,checkin_report_at,checkout_report_at,status)values($1,$2,$3,$4,$5,$4,$5,$6)",[id(n),e,p,ci,co,co?'completed':'working']);
 const events={...cfg,start_kind:'checkout',end_kind:'checkin',start_time:null,end_time:null};
 assert.equal((await per(events,'2026-11-19T10:00+09')).start,'2026-11-18T10:00:00+00:00');assert.equal((await per(events,'2026-11-19T10:00+09')).end,'2026-11-18T23:45:00+00:00');
 await call('save',events);assert.equal((await call('get')).settings.start_time,null);
 // Other property's message and old-only conversation cannot enter this period.
 await db.query("insert into omg_private.online_connections(property_id,beds_property_id,properties)values($1,123,'[]'),($2,456,'[]')",[p,other]);
 const preview=await call('preview',cfg),rid=preview.run.id,st=preview.run.period_start,et=preview.run.period_end;
 for(const [prop,bid,mid,source,body,time] of [[p,10,1,'guest','문이 안 열립니다',st],[p,10,2,'host','확인하겠습니다',st],[other,11,3,'guest','다른 지점 비밀',st],[p,12,4,'guest','old',new Date(new Date(st)-86400000).toISOString()],[p,13,5,'guest','end boundary',et]])await db.query("insert into omg_private.online_messages(property_id,id,booking_id,source,body,sent_at)values($1,$2,$3,$4,$5,$6)",[prop,mid,bid,source,body,time]);
 await call('run',{id:rid});await call('run',{id:rid});
 // No provider: failed, explicit reason, zero debit.
 await work('claim');let run=(await call('logs')).logs[0];assert.equal(run.status,'failed');assert.equal(Number(run.credits),0);
 await db.exec("insert into omg_private.ai_provider(singleton,enabled,vault_id)values(true,true,gen_random_uuid()) on conflict(singleton)do update set enabled=true,vault_id=excluded.vault_id");
 await db.query("insert into omg_private.ai_wallets(property_id,balance_micro,monthly_limit_micro)values($1,1000000,1000000)",[p]);
 const b=await call('preview',cfg);await call('run',{id:b.run.id});const job=await work('claim');assert.equal(job.inputs.length,1);assert.equal(job.inputs[0].messages.length,2);assert.equal(job.inputs[0].room_number,'객실 미확인');
 await work('attempt',{id:job.id,lease:job.lease});assert.equal((await work('attempt',{id:job.id,lease:job.lease})).stale,true);
 const res={id:job.id,lease:job.lease,input_tokens:1000,output_tokens:200,cached_tokens:100,summary:'시설 고장 확인 필요',issues:[{room_number:'객실 미확인'}]};
 await work('finish',res);await work('finish',res);run=(await call('logs')).logs[0];assert.equal(Number(run.credits),.191);assert.equal((await query('select balance_micro from omg_private.ai_wallets where property_id=$1',[p])).balance_micro,999809);assert.equal((await query('select count(*) n from property_messages')).n,0,'manual never messages staff');
 await work('schedule');await work('schedule');assert.equal((await query("select count(*) n from omg_private.briefing_runs where mode='auto'")).n,0,'enabling now does not backfill old scheduled periods');
 // Scheduled delivery uses the selected union and waits for each actual report.
 const delivery={...cfg,notify_kind:'checkin',notify_time:null,notify_targets:['onsite',e1,e2]};
 await assert.rejects(()=>call('save',{...delivery,notify_targets:[e3]}),/근무자/);
 await call('save',delivery);
 assert.deepEqual((await call('get')).employees.map(x=>x.id),[e1,e2]);
 await db.query("update omg_private.briefing_settings set enabled_since=$1 where property_id=$2",[st,p]);
 await work('schedule');await work('schedule');
 assert.equal((await query("select count(*) n from omg_private.briefing_runs where mode='auto'")).n,1);
 const auto=await work('claim');await work('finish',{...res,id:auto.id,lease:auto.lease});
 assert.equal((await query("select count(*) n from omg_private.briefing_deliveries")).n,2,'role and explicit employee are deduped');
 await db.query("delete from public.work_sessions where employee_id in ($1,$2)",[e1,e2]);
 assert.deepEqual(await work('pushes'),[]);
 await db.query("insert into work_sessions(id,employee_id,property_id,clock_in_at,checkin_report_at,status)values($1,$2,$3,now(),now(),'working')",[id(51),e1,p]);
 const first=await work('pushes');assert.equal(first.length,1);
 assert.equal((await query("select employee_id from property_message_recipients")).employee_id,e1);
 assert.deepEqual(await work('pushes'),first,'retry keeps the same dispatch IDs');
 await work('pushed',{id:first[0].id});assert.deepEqual(await work('pushes'),[]);
 await db.query("insert into work_sessions(id,employee_id,property_id,clock_in_at,checkin_report_at,status)values($1,$2,$3,now(),now(),'working')",[id(52),e2,p]);
 assert.equal((await work('pushes')).length,1);
 // Fixed-time all-staff delivery is calculated in the property timezone.
 await db.query(`insert into omg_private.briefing_runs(id,property_id,mode,status,period_start,period_end,timezone,settings,summary,finished_at)
 values($1,$2,'auto','completed','2026-11-18 18:59+09','2026-11-19 09:00+09','Asia/Seoul',$3,'fixed summary',now())`,[id(60),p,JSON.stringify({notify_kind:'time',notify_time:'10:15',notify_targets:['all']})]);
 await db.query('select omg_private.briefing_enqueue_delivery(r) from omg_private.briefing_runs r where id=$1',[id(60)]);
 assert.equal((await query("select count(*) n from omg_private.briefing_deliveries where run_id=$1 and due_at='2026-11-19 10:15+09'",[id(60)])).n,2);
 await db.query("update omg_private.briefing_deliveries set due_at=now()+interval '1 hour' where run_id=$1",[id(60)]);
 assert.equal((await work('pushes')).length,1,'fixed deliveries are still waiting');
 await db.query("update omg_private.briefing_deliveries set due_at=now()-interval '1 minute' where run_id=$1",[id(60)]);
 assert.equal((await work('pushes')).length,3,'fixed-time deliveries become due');
 await db.query("insert into property_share_requests(requester_property_id,target_property_id,status,requested_permissions) values($1,$2,'approved',array['messages'])",[other,p]);
 await call('save',{...delivery,notify_targets:[e3]});
 const roster=await call('get');
 assert.equal(roster.employees.find(e=>e.id===e3).property_id,other);
 assert.match(roster.properties.find(x=>x.id===other).name,/타지점/);
 await db.query(`insert into omg_private.briefing_runs(id,property_id,mode,status,period_start,period_end,timezone,settings,summary,finished_at)
 values($1,$2,'auto','completed',now()-interval '2 hours',now()-interval '1 hour','Asia/Seoul',$3,'shared summary',now())`,[id(61),p,JSON.stringify({notify_kind:'checkin',notify_targets:[e3]})]);
 await db.query('select omg_private.briefing_enqueue_delivery(r) from omg_private.briefing_runs r where id=$1',[id(61)]);
 assert.equal((await query('select employee_id from omg_private.briefing_deliveries where run_id=$1',[id(61)])).employee_id,e3);
 await db.query("insert into work_sessions(id,employee_id,property_id,clock_in_at,checkin_report_at,status) values($1,$2,$3,now(),now(),'working')",[id(62),e3,other]);
 await db.query("update property_share_requests set status='pending' where requester_property_id=$1",[other]);
 assert.equal((await work('pushes')).length,3,'revoked sharing blocks pending message');
 await db.query("update property_share_requests set status='approved' where requester_property_id=$1",[other]);
 assert.equal((await work('pushes')).length,4,'the remote check-in releases its authorized briefing');

 // A crash after attempted request settles conservatively once, with explicit estimated flag.
 const c=await call('preview',cfg);await call('run',{id:c.run.id});const lost=await work('claim');await work('attempt',{id:lost.id,lease:lost.lease});await db.query("update omg_private.briefing_runs set leased_until=now()-interval '1 second' where id=$1",[lost.id]);await work('claim');const failed=(await call('logs')).logs.find(x=>x.id===lost.id);assert.equal(failed.status,'failed');assert.equal(failed.estimated,true);assert.ok(Number(failed.credits)>0);
 // A confirmed test sends to its current audience even while automatic delivery is off.
 await call('save',{...cfg,enabled:false});
 await assert.rejects(()=>call('preview',{...cfg,notify_targets:[id(999)]}),/근무자/);
 const test=await call('preview',{...cfg,notify_targets:[e1]});
 assert.equal((await query("select count(*) n from omg_private.briefing_deliveries where run_id=$1",[test.run.id])).n,0);
 await call('run',{id:test.run.id});
 const manual=await work('claim');assert.equal(manual.id,test.run.id);
 await work('finish',{...res,id:manual.id,lease:manual.lease,issues:[]});
 await work('finish',{...res,id:manual.id,lease:manual.lease,issues:[]});
 await work('pushes');
 const sent=await query(`select m.message,r.employee_id from omg_private.briefing_deliveries d
  join property_messages m on m.id=d.message_ids[1] join property_message_recipients r on r.message_id=m.id
  where d.run_id=$1`,[manual.id]);
 assert.equal(sent.employee_id,e1);assert.match(sent.message,/\[테스트\]/);
 assert.equal((await query("select count(*) n from omg_private.briefing_deliveries where run_id=$1",[manual.id])).n,1);
 await db.query("delete from omg_private.online_messages where property_id=$1",[p]);
 const noMessages=await call('preview',{...cfg,notify_targets:[e2]});await call('run',{id:noMessages.run.id});
 await work('claim');await work('pushes');
 const empty=await query(`select m.message from omg_private.briefing_deliveries d
  join property_messages m on m.id=d.message_ids[1] where d.run_id=$1`,[noMessages.run.id]);
 assert.match(empty.message,/새로 수신한 게스트 대화가 없습니다/);
 console.log('PASS: tenant/role authorization, overnight and attendance boundaries, new-message filtering, dedupe, billing, timeout recovery and recipients');await db.close();
})().catch(e=>{console.error(e);process.exit(1);});
