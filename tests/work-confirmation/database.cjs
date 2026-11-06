const {PGlite}=require('@electric-sql/pglite'),fs=require('fs'),assert=require('node:assert/strict'),{randomUUID}=require('crypto');
const db=new PGlite();let checks=0;
const ok=(v,label)=>{assert.ok(v,label);checks++};
const q=async(sql,args=[]) =>(await db.query(sql,args)).rows;
const one=async(sql,args=[])=>(await q(sql,args))[0];
const rpc=async(name,args=[])=>{await db.exec('set role anon');try{return(await one(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).result}finally{await db.exec('reset role')}};
(async()=>{
await db.exec('create role anon;create role authenticated;create role service_role;grant usage on schema public to anon,authenticated;create schema omg_private;create schema cron;');
await db.exec(fs.readFileSync('supabase/migrations/001_initial_schema.sql','utf8'));
await db.exec(`alter table employees add report_config jsonb,add login_failures int default 0,add login_locked_until timestamptz;
alter table properties add management_number int default 1,add clock_in_basis text default 'report',add clock_in_report_offset_minutes int default 0,add attendance_nfc_tags text[] default '{}';
alter table work_sessions add token_expires_at timestamptz default '-infinity',add first_login_at timestamptz,add nfc_entry_at timestamptz,add nfc_tag_uid text;
alter table work_sessions drop constraint work_sessions_shift_check;alter table work_sessions add check(shift in('general','morning','afternoon'));
drop index one_open_work_session_per_employee;create unique index one_open_work_session_per_employee on work_sessions(employee_id) where status='working' and clock_out_at is null;
create unique index work_session_token_unique on work_sessions(login_token_hash);
alter table work_reports add make_accepted_at timestamptz;
create table owners(id uuid primary key,property_id uuid,active boolean);
create table owner_sessions(id uuid,owner_id uuid,property_id uuid,login_token_hash text,token_expires_at timestamptz);
create table property_share_requests(requester_property_id uuid,target_property_id uuid,status text,requested_permissions text[]);
create table attendance_adjustment_requests(id uuid primary key default gen_random_uuid(),business_id uuid,property_id uuid,employee_id uuid,work_session_id uuid,original_clock_in_at timestamptz,original_clock_out_at timestamptz,requested_clock_in_at timestamptz,requested_clock_out_at timestamptz,status text default 'pending',approved_at timestamptz,approved_by uuid);
create table native_push_devices(session_hash text,expires_at timestamptz);
create table property_messages(id uuid primary key default gen_random_uuid(),business_id uuid,property_id uuid,sender_type text,message text,priority text,message_type text,source text,sender_employee_id uuid,attendance_request_id uuid);
create table property_message_recipients(message_id uuid,recipient_key text,recipient_type text,employee_id uuid,owner_id uuid,read_at timestamptz);
create table omg_private.chat_push_outbox(message_id uuid primary key);
create function omg_private.token_hash(uuid) returns text language sql immutable strict as $$select encode(sha256(convert_to($1::text,'UTF8')),'hex')$$;
create function omg_private.pin_matches(text,text) returns boolean language sql as $$select $1=$2$$;
create function public.evaluate_attendance_warnings(uuid,text) returns jsonb language sql as $$select '{}'::jsonb$$;
create function omg_private.dispatch_chat_push(uuid) returns void language sql as $$select$$;
create function cron.schedule(text,text,text) returns int language sql as $$select 1$$;`);
await db.exec(fs.readFileSync(fs.readdirSync('supabase/migrations').map(n=>'supabase/migrations/'+n).find(n=>n.endsWith('_work_shift_confirmation.sql')),'utf8'));
await db.exec('grant execute on function public.get_work_session(uuid),public.save_work_report(uuid,text,jsonb),public.attendance_nfc_entry(uuid,text),public.start_work_session(uuid,text,text,text,text) to anon,authenticated');
const approval=fs.readFileSync('supabase/migrations/20261011093319_block_future_attendance_adjustments.sql','utf8');await db.exec(approval.slice(0,approval.indexOf('CREATE OR REPLACE FUNCTION public.owner_update_attendance(')).trim()+';');await db.exec('grant execute on function public.approve_attendance_adjustment(uuid,uuid) to anon');
const emps=await q('select * from employees order by id');const stamp=new Date('2026-11-07T00:00:00Z');
async function session(emp,n=0){const token=randomUUID();const s=await one(`insert into work_sessions(business_id,property_id,employee_id,shift,work_date,clock_in_at,login_token_hash,token_expires_at) values($1,$2,$3,'general','2026-11-06',$4,omg_private.token_hash($5),now()+interval '20 hours') returning id`,[emp.business_id,emp.property_id,emp.id,new Date(Date.now()-14*3600000).toISOString(),token]);await db.query('insert into native_push_devices values(omg_private.token_hash($1),now()+interval \'20 hours\')',[token]);return{id:s.id,token};}
const a=await session(emps[0]);
await db.query('select omg_private.process_work_confirmation($1,now()+interval \'40 hours\')',[a.id]);ok((await q('select * from omg_private.work_confirmations')).length===0,'login without report has no 12-hour prompt');
const saved=await rpc('save_work_report',[a.token,'clock_in',{}]);ok(saved.ok,'real clock-in report succeeds');
let s=await one('select * from work_sessions where id=$1',[a.id]);ok((await one("select token_expires_at='infinity'::timestamptz infinite from work_sessions where id=$1",[a.id])).infinite,'report persists login');ok((await one("select expires_at='infinity'::timestamptz infinite from native_push_devices where session_hash=omg_private.token_hash($1)",[a.token])).infinite,'push lifetime follows session');
await db.query('select omg_private.process_work_confirmation($1,$2)',[a.id,new Date(Date.parse(s.checkin_report_at)+12*3600000-1)]);ok((await q('select * from omg_private.work_confirmations')).length===0,'not before 12 hours');
// Move only the test shift's due time so public confirmation uses the real server clock.
await db.query("update work_sessions set next_confirmation_at=clock_timestamp()-interval '1 second' where id=$1",[a.id]);
let result=await rpc('work_shift_confirmation',[a.token,null]);const first=result.pending.id;ok(result.pending&&Date.parse(result.pending.deadline_at)-Date.parse(result.pending.requested_at)===600000,'exact 10-minute server window');
await rpc('work_shift_confirmation',[a.token,null]);ok((await q('select * from omg_private.work_confirmations')).length===1,'status refresh does not duplicate alert');
const b=await session(emps[1]);ok(!(await rpc('work_shift_confirmation',[b.token,first])).ok,'another employee cannot confirm');
result=await rpc('work_shift_confirmation',[a.token,first]);ok(result.confirmed&&!result.pending,'yes confirms');
s=await one('select * from work_sessions where id=$1',[a.id]);const c=await one('select * from omg_private.work_confirmations where id=$1',[first]);ok(Date.parse(s.next_confirmation_at)-Date.parse(c.due_at)===43200000,'next check is 12 hours from prior interval');
const next=s.next_confirmation_at;await rpc('work_shift_confirmation',[a.token,first]);ok(String((await one('select next_confirmation_at from work_sessions where id=$1',[a.id])).next_confirmation_at)===String(next),'duplicate confirmation cannot extend time');
// The next interval opens another independent prompt; expire at exactly deadline.
await db.query('select omg_private.process_work_confirmation($1,$2)',[a.id,next]);let pending=await one('select * from omg_private.work_confirmations where id<>$1',[first]);
await db.query('select omg_private.process_work_confirmation($1,$2)',[a.id,new Date(Date.parse(pending.deadline_at)-1)]);ok((await one('select status from work_sessions where id=$1',[a.id])).status==='working','deadline minus 1ms still working');
await db.query('select omg_private.process_work_confirmation($1,$2)',[a.id,pending.deadline_at]);
s=await one('select * from work_sessions where id=$1',[a.id]);ok(s.status==='completed'&&s.clock_out_at===null&&s.checkout_report_at===null&&s.unconfirmed_ended_at,'timeout ends presence with no invented checkout/report');
result=await rpc('work_shift_confirmation',[a.token,pending.id]);ok(!result.confirmed&&!result.pending,'late confirmation cannot revive work');
result=await rpc('get_work_session',[a.token]);ok(result.ok&&result.status==='completed'&&result.expires_at==='9999-12-31T23:59:59Z','same login remains usable after timeout');
ok(!(await rpc('save_work_report',[a.token,'clock_out',{}])).ok,'late checkout cannot silently fill missing timestamp');
const newShift=await rpc('begin_next_work_shift',[a.token]);ok(newShift.ok&&newShift.session_id!==a.id&&newShift.status==='working','new shift starts without logout');ok((await rpc('begin_next_work_shift',[a.token])).session_id===newShift.session_id,'duplicate start is idempotent');
ok((await one('select clock_out_at from work_sessions where id=$1',[a.id])).clock_out_at===null,'old missing checkout preserved');
// Missing checkout can be corrected for a multi-day shift through the existing owner approval.
await db.query("update work_sessions set work_date='2026-10-01',clock_in_at='2026-10-01T00:00Z' where id=$1",[a.id]);
ok(!(await rpc('request_missing_checkout_adjustment',[b.token,a.id,'09:00','22:00','2026-10-02'])).ok,'cannot edit another worker');
ok(!(await rpc('request_missing_checkout_adjustment',[a.token,a.id,'09:00','22:00','2099-01-01'])).ok,'future correction denied');
const correction=await rpc('request_missing_checkout_adjustment',[a.token,a.id,'09:00','22:00','2026-10-02']);ok(correction.ok,'employee requests actual multi-day checkout');
ok((await one('select clock_out_at from work_sessions where id=$1',[a.id])).clock_out_at===null,'request does not invent approved payroll time');
const owner=randomUUID(),ownerToken=randomUUID();await db.query('insert into owners values($1,$2,true)',[owner,emps[0].property_id]);await db.query("insert into owner_sessions values(gen_random_uuid(),$1,$2,omg_private.token_hash($3),now()+interval '1 day')",[owner,emps[0].property_id,ownerToken]);
ok((await rpc('approve_attendance_adjustment',[ownerToken,correction.request_id])).ok,'owner approves correction');
ok(Number((await one('select extract(epoch from clock_out_at-clock_in_at)/3600 hours from work_sessions where id=$1',[a.id])).hours)===37,'actual 37-hour correction stored without 24-hour truncation');
// Normal checkout cancels an active prompt; subsequent confirmation cannot reopen.
await rpc('save_work_report',[b.token,'clock_in',{}]);await db.query("update work_sessions set next_confirmation_at=now()-interval '1 second' where id=$1",[b.id]);const bp=(await rpc('work_shift_confirmation',[b.token])).pending.id;
await rpc('save_work_report',[b.token,'clock_out',{}]);ok(!(await rpc('work_shift_confirmation',[b.token,bp])).confirmed,'normal checkout wins over continuation');
await db.exec('set role anon');try{await db.query('select * from omg_private.work_confirmations');assert.fail('private table readable')}catch(e){ok(e.code==='42501','private confirmation records denied')}finally{await db.exec('reset role')}
ok(!(await rpc('work_shift_confirmation',[randomUUID(),null])).ok,'invalid session denied');
console.log('PASS '+checks+' attendance continuation assertions');
await db.close();})().catch(async e=>{console.error(e.message,e.code,e.position,e.where); if(e.query&&e.position)console.error(e.query.slice(Number(e.position)-150,Number(e.position)+150));await db.close();process.exitCode=1});
