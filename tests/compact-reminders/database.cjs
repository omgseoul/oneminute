const fs=require('fs'),{PGlite}=require('@electric-sql/pglite'),assert=require('node:assert/strict'),{randomUUID}=require('crypto');
const db=new PGlite();let checks=0;const ok=(v,m)=>{assert.ok(v,m);checks++};const q=async(s,a=[])=>(await db.query(s,a)).rows;const one=async(s,a=[])=>(await q(s,a))[0];
const rpc=async(name,args=[])=>{await db.exec('set role anon');try{return(await one(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).result}finally{await db.exec('reset role')}};
(async()=>{
// Use the same disposable legacy schema as the checkout regression suite.
const fixture=fs.readFileSync('tests/notification-checkout/database.cjs','utf8');const setup=fixture.slice(fixture.indexOf("await db.exec('create role"),fixture.indexOf('const emps=await q'));
await eval('(async()=>{'+setup+'})()');
await db.exec(fs.readFileSync('supabase/migrations/20261107035108_checkin_report_warning.sql','utf8'));
const e=await one('select * from employees order by id limit 1'),token=randomUUID();await db.query("update employees set scheduled_clock_in='14:00',scheduled_clock_out='19:00' where id=$1",[e.id]);
const s=await one("insert into work_sessions(business_id,property_id,employee_id,shift,work_date,clock_in_at,checkin_report_at,login_token_hash,token_expires_at)values($1,$2,$3,'general','2026-11-06','2026-11-06T01:11Z','2026-11-06T01:11Z',omg_private.token_hash($4),'infinity') returning id",[e.business_id,e.property_id,e.id,token]);
await db.query("insert into attendance_warning_rules(business_id,property_id,event_type,comparison,threshold_minutes,message,active,before_checkout,target_all)values($1,$2,'clock_out','early',30,'{이름}: {예정시간} / {실제시간} / {차이분}',true,true,true)",[e.business_id,e.property_id]);
const pending=async t=>(await one('select omg_private.pending_checkout_warnings($1,$2) w',[s.id,t])).w;
ok((await pending('2026-11-07T07:08:00.80845Z')).length===0,'reproduce original incident: prior work date incorrectly skips early warning');
await db.exec(fs.readFileSync('supabase/migrations/20261107073216_checkout_warning_schedule_cycle.sql','utf8'));
let warnings=await pending('2026-11-07T07:08:00.80845Z');ok(warnings.length===1,'same incident now warns');ok(warnings[0].expected_at==='2026-11-07T10:00:00+00:00','reference is current shift 19:00');ok(warnings[0].timezone==='Asia/Seoul'&&warnings[0].actual_at,'popup includes dated basis');
ok((await pending('2026-11-07T09:30:00Z')).length===1,'exactly thirty minutes early warns');ok((await pending('2026-11-07T09:30:01Z')).length===0,'29m59s early does not round into thirty');
await db.query("update attendance_warning_rules set comparison='late'");ok((await pending('2026-11-07T10:30:00Z')).length===1,'exactly thirty minutes late warns');ok((await pending('2026-11-07T10:29:59Z')).length===0,'29m59s late stays below threshold');await db.query("update attendance_warning_rules set comparison='early'");
const expected=async(day,start,end,actual,zone='Asia/Seoul')=>(await one('select omg_private.checkout_warning_expected_at($1,$2,$3,$4,$5)::text t',[day,start,end,zone,actual])).t;
ok(await expected('2026-11-06','14:00','19:00','2026-11-06T15:30Z')==='2026-11-06 10:00:00+00','after midnight before next start retains prior shift');
ok(await expected('2026-11-06','22:00','06:00','2026-11-06T20:00Z')==='2026-11-06 21:00:00+00','normal overnight exit retains next morning');
ok(await expected('2026-11-06','22:00','06:00','2026-11-07T04:00Z')==='2026-11-06 21:00:00+00','late overnight exit before next start remains late');
ok(await expected('2026-11-06','22:00','06:00','2026-11-07T20:00Z')==='2026-11-07 21:00:00+00','multi-day overnight session advances by schedule cycle');
ok(await expected('2026-11-06','14:00','19:00','2026-11-07T05:00Z')==='2026-11-07 10:00:00+00','exact next scheduled start advances reference');
ok(await expected('2026-11-07','09:00','17:00','2026-11-07T20:00Z','America/New_York')==='2026-11-07 22:00:00+00','property timezone controls schedule');
// Actual save must still block until explicit acknowledgment, with unchanged attendance values.
await db.query("update employees set scheduled_clock_in=((clock_timestamp() at time zone 'Asia/Seoul')-interval '2 hours')::time,scheduled_clock_out=((clock_timestamp() at time zone 'Asia/Seoul')+interval '2 hours')::time where id=$1",[e.id]);
await db.query("update work_sessions set work_date=(clock_timestamp() at time zone 'Asia/Seoul')::date-1,clock_in_at=clock_timestamp()-interval '30 hours',checkin_report_at=clock_timestamp()-interval '30 minutes',next_confirmation_at=clock_timestamp()+interval '12 hours' where id=$1",[s.id]);
const before=await one('select work_date,clock_in_at from work_sessions where id=$1',[s.id]);
let result=await rpc('save_work_report',[token,'clock_out',{}]);ok(result.code==='checkout_warning_required','server save gate uses corrected schedule');ok((await q('select * from work_reports')).length===0,'no report before acknowledgment');
let w=result.warnings[0];ok((await rpc('confirm_checkout_warning',[token,w.rule_id,w.rule_updated_at])).ok,'explicit confirmation works');ok((await rpc('save_work_report',[token,'clock_out',{}])).ok,'save succeeds only after acknowledgment');
ok((await rpc('evaluate_attendance_warnings',[token,'clock_out'])).message_ids.length===0,'no duplicate post-checkout warning');
await db.query('update attendance_warning_rules set before_checkout=false');ok((await rpc('evaluate_attendance_warnings',[token,'clock_out'])).message_ids.length===1,'post-checkout option uses same recurring schedule');ok((await rpc('evaluate_attendance_warnings',[token,'clock_out'])).message_ids.length===0,'post-checkout retry deduplicates');
const after=await one('select work_date,clock_in_at from work_sessions where id=$1',[s.id]);ok(JSON.stringify(before)===JSON.stringify(after),'work date and clock-in record unchanged');
await db.exec('set role anon');try{await db.query("select omg_private.checkout_warning_expected_at('2026-11-06','14:00','19:00','Asia/Seoul',now())");assert.fail('helper exposed')}catch(err){ok(err.code==='42501','private helper cannot be called by client')}finally{await db.exec('reset role')}
console.log('PASS '+checks+' schedule-cycle warning assertions, including exact incident reproduction');await db.close();
})().catch(async e=>{console.error(e);await db.close();process.exitCode=1});
