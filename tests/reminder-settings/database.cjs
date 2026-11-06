const {PGlite}=require('@electric-sql/pglite'),fs=require('fs'),assert=require('node:assert/strict');
const db=new PGlite(),id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
(async()=>{
await db.exec(`create role anon;create role authenticated;create role service_role;create schema omg_private;create schema vault;create schema net;
create table vault.decrypted_secrets(name text,decrypted_secret text);insert into vault.decrypted_secrets values('omg_guest_email_worker_secret','fixture');
create table net.calls(body jsonb);create function net.http_post(url text,headers jsonb,body jsonb) returns bigint language plpgsql as $$begin insert into net.calls values(body);return 1;end$$;
create function omg_private.can_manage_shared_property(uuid,uuid,text) returns boolean language sql as $$select $1='${id(101)}'::uuid and $2='${id(1)}'::uuid$$;
create table properties(id uuid primary key,business_id uuid,timezone text);
create table employees(id uuid primary key,property_id uuid,active boolean default true,role text default 'staff');
create table owners(id uuid primary key,property_id uuid,active boolean default true);
create table work_sessions(id uuid default gen_random_uuid(),property_id uuid,employee_id uuid,checkin_report_at timestamptz,clock_out_at timestamptz,checkout_report_at timestamptz,status text default 'working');
create table missions(id uuid primary key,title text,property_id uuid,active boolean default true,owner_completed_at timestamptz,due_at timestamptz,target_employee_ids jsonb default '[]',completion_mode text default 'all');
create table mission_completions(mission_id uuid,employee_id uuid);
create table calendar_events(id uuid primary key,title text,property_id uuid,start_at timestamptz,target_employee_ids uuid[],holiday_request_id uuid);
create table property_messages(id uuid primary key default gen_random_uuid(),business_id uuid,property_id uuid,sender_type text,message text,priority text,message_type text,source text);
create table property_message_recipients(message_id uuid references property_messages(id),recipient_key text,recipient_type text,employee_id uuid,owner_id uuid,primary key(message_id,recipient_key));
create table property_reminder_settings(property_id uuid,kind text,send_when text default 'before',send_time time default '09:00',notify_staff boolean default true,notify_owner boolean default true,schedules jsonb default '[]',primary key(property_id,kind));
create table reminder_deliveries(kind text,item_id uuid,offset_days smallint,send_time time,message_id uuid references property_messages(id),created_at timestamptz default now(),primary key(kind,item_id,offset_days,send_time));
insert into properties values('${id(1)}','${id(99)}','Asia/Seoul'),('${id(2)}','${id(99)}','America/New_York');
insert into employees(id,property_id) values('${id(21)}','${id(1)}'),('${id(22)}','${id(1)}'),('${id(23)}','${id(2)}');
insert into owners(id,property_id) values('${id(11)}','${id(1)}');`);
const old=fs.readFileSync('supabase/migrations/20261005070600_multi_reminder_schedules.sql','utf8');await db.exec(old.slice(old.indexOf('CREATE OR REPLACE FUNCTION public.get_property_reminder_settings'),old.indexOf('CREATE OR REPLACE FUNCTION public.save_property_reminder_settings')));
await db.exec(fs.readFileSync('supabase/migrations/20261105102827_reminder_checkin_and_overdue.sql','utf8'));
await db.exec(fs.readFileSync('supabase/migrations/20261106015155_daily_reminders_registration_alerts.sql','utf8'));
const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
const rule=(extra={})=>({offset_days:0,send_time:'09:00',...extra});
const section=(kind,schedules)=>({kind,schedules,notify_staff:true,notify_owner:true});
const save=async(todo,calendar=[],token=id(101))=>(await q('select save_property_reminder_settings($1,$2,$3) r',[token,id(1),JSON.stringify([section('todo',todo),section('calendar',calendar)])]))[0].r;
assert.equal((await save([rule()],[],id(999))).ok,false);
assert.equal((await save([rule()])).ok,true);
assert.equal((await save([rule({trigger:'checkin',repeat_overdue:true})],[rule({trigger:'checkin'})])).ok,true);
let stored=(await q("select schedules from property_reminder_settings where kind='todo'"))[0].schedules;
assert.equal(stored[0].trigger,'checkin');assert.equal(stored[0].repeat_overdue,true);assert(stored[0].enabled_at);
assert.equal((await save([rule({trigger:'checkin',repeat_overdue:true,enabled_at:'2000-01-01'})],[rule()])).ok,true);
assert.equal((await q("select schedules from property_reminder_settings where kind='todo'"))[0].schedules[0].enabled_at,stored[0].enabled_at,'server activation preserved, client timestamp ignored');
const before=JSON.stringify(await q('select * from property_reminder_settings order by kind'));
assert.equal((await save([rule()],[rule({repeat_overdue:true})])).ok,false);
assert.equal(JSON.stringify(await q('select * from property_reminder_settings order by kind')),before,'invalid second section does not partially save first');
for(const bad of [{offset_days:-1},{offset_days:366},{send_time:'25:00'},{trigger:'login'},{repeat_overdue:'yes'}])assert.equal((await save([rule(bad)])).ok,false,JSON.stringify(bad));
assert.equal((await save([rule({trigger:'checkin'}),rule({trigger:'checkin',send_time:'10:00'})])).ok,false,'same check-in rule cannot be duplicated via unused time');
assert.equal((await save(Array.from({length:11},(_,i)=>rule({offset_days:i})))).ok,false);
await save([rule({repeat_overdue:true})],[rule()]);
await db.exec(`insert into missions(id,title,property_id,due_at) values('${id(31)}','할 일','${id(1)}','2030-01-10T00:00Z');
insert into calendar_events values('${id(41)}','일정','${id(1)}','2030-01-10T00:00Z',array['${id(21)}'::uuid],null);`);
const run=async(t)=>(await q('select omg_private.enqueue_due_reminders_at($1) n',[t]))[0].n;
assert.equal(await run('2030-01-10T00:00Z'),2);assert.equal(await run('2030-01-10T00:00:30Z'),0);
assert.equal(await run('2030-01-11T00:00Z'),1,'overdue repeats next day, calendar does not');
assert.equal(await run('2030-01-11T00:01Z'),0,'not every cron minute');
await db.exec(`insert into mission_completions values('${id(31)}','${id(21)}')`);
assert.equal(await run('2030-01-12T00:00Z'),1);
let recips=await q("select pr.employee_id from property_message_recipients pr join reminder_deliveries d on d.message_id=pr.message_id where d.delivery_key='overdue:2030-01-12' and pr.employee_id is not null");assert.deepEqual(recips.map(r=>r.employee_id),[id(22)],'already completed employee excluded');
await db.exec(`insert into mission_completions values('${id(31)}','${id(22)}')`);assert.equal(await run('2030-01-13T00:00Z'),0,'all completed stops owner and staff');
await db.exec(`delete from mission_completions;update missions set completion_mode='any';insert into mission_completions values('${id(31)}','${id(21)}')`);assert.equal(await run('2030-01-14T00:00Z'),0,'any completed stops everyone');
await db.exec(`delete from mission_completions;update missions set owner_completed_at=now()`);assert.equal(await run('2030-01-15T00:00Z'),0,'owner completion stops reminders');
await db.exec('update missions set owner_completed_at=null,active=false');assert.equal(await run('2030-01-16T00:00Z'),0,'ended task stops reminders');
await db.exec("update missions set active=true,completion_mode='all'");
// Two different lead times sharing one overdue time send one daily reminder.
await save([rule({repeat_overdue:true}),rule({offset_days:1,repeat_overdue:true})]);assert.equal(await run('2030-01-17T00:00Z'),1);
await save([rule({trigger:'checkin',repeat_overdue:true})],[rule({trigger:'checkin'})]);
await db.exec(`insert into work_sessions(property_id,employee_id) values('${id(1)}','${id(21)}'),('${id(1)}','${id(22)}'),('${id(2)}','${id(23)}');`);
assert.equal(await run('2030-01-18T00:00Z'),0,'login or NFC without report does not send');
await db.exec(`update work_sessions set checkin_report_at='2000-01-01' where employee_id='${id(21)}'`);assert.equal(await run('2030-01-18T00:00Z'),0,'old check-in is not reused');
await db.exec(`update work_sessions set checkin_report_at='2030-01-18T00:02Z' where employee_id in ('${id(21)}','${id(23)}')`);
assert.equal(await run('2030-01-18T00:02Z'),1);assert.equal(await run('2030-01-18T00:03Z'),0,'check-in does not repeat every minute');
await db.exec(`update work_sessions set checkin_report_at='2030-01-18T01:02Z' where employee_id='${id(22)}'`);assert.equal(await run('2030-01-18T01:02Z'),1,'later colleague receives their own reminder');
assert.equal((await q("select count(*)::int n from property_message_recipients p join reminder_deliveries d on d.message_id=p.message_id where d.delivery_key like 'checkin:2030-01-18:%' and p.owner_id is not null"))[0].n,1,'owner receives one reminder per item/day');
assert.equal((await q("select count(*)::int n from property_message_recipients where employee_id=$1",[id(23)]))[0].n,0,'other branch excluded');
assert.equal(await run('2030-01-19T00:02Z'),0,'yesterday check-in does not trigger new day');
await db.exec(`update work_sessions set checkin_report_at='2030-01-19T00:02Z' where employee_id='${id(21)}'`);assert.equal(await run('2030-01-19T00:02Z'),1,'new check-in repeats overdue next day');
await db.exec(`update calendar_events set start_at='2030-01-20T00:00Z';update work_sessions set checkin_report_at='2030-01-20T00:02Z' where employee_id='${id(21)}'`);assert.equal(await run('2030-01-20T00:02Z'),2,'calendar check-in supported');
// An owner-only calendar item can notify the owner when a worker checks in,
// without exposing that calendar item to the worker.
await db.exec(`update calendar_events set target_employee_ids='{}',start_at='2030-01-21T00:00Z';update work_sessions set checkin_report_at='2030-01-21T00:02Z' where employee_id='${id(21)}'`);
assert.equal(await run('2030-01-21T00:02Z'),2);
const ownerCalendar=await q("select pr.recipient_type from property_message_recipients pr join reminder_deliveries d on d.message_id=pr.message_id where d.kind='calendar' and d.delivery_key like 'checkin:2030-01-21:%'");assert.deepEqual(ownerCalendar.map(x=>x.recipient_type),['owner']);
await save([rule({offset_days:0})]);assert.equal(await run('2030-01-21T00:00Z'),0,'turning overdue off stops future reminders');
// A historical fixed-time delivery with an empty key remains deduplicated after migration.
await db.exec(`update missions set due_at='2030-01-22T00:00Z'`);assert.equal(await run('2030-01-22T00:00Z'),1,'new due date gets a fresh daily notification');
// Local time, not UTC, governs the fixed-time schedule.
await db.exec(`insert into property_reminder_settings(property_id,kind,schedules) values('${id(2)}','todo','[{"offset_days":0,"send_time":"09:00"}]');insert into missions(id,title,property_id,due_at) values('${id(32)}','뉴욕 지점','${id(2)}','2030-02-01T17:00Z');`);
assert.equal(await run('2030-02-01T00:00Z'),0);assert.equal(await run('2030-02-01T14:00Z'),1,'09:00 New York time');
// A same-day report before rule activation must not generate an alert.
await save([rule({trigger:'checkin',repeat_overdue:true})]);
await db.exec(`update property_reminder_settings set schedules=jsonb_set(schedules,'{0,enabled_at}','"2030-02-02T01:00Z"') where property_id='${id(1)}' and kind='todo';update work_sessions set checkin_report_at='2030-02-02T00:30Z' where employee_id='${id(21)}'`);
assert.equal(await run('2030-02-02T01:01Z'),0,'same-day report predating activation ignored');
await db.exec(`update work_sessions set checkin_report_at='2030-02-02T01:02Z' where employee_id='${id(21)}'`);assert.equal(await run('2030-02-02T01:02Z'),1);
assert.equal((await q("select has_function_privilege('anon','omg_private.enqueue_due_reminders_at(timestamptz)','execute') allowed"))[0].allowed,false);
// A newly registered item alerts targets even with every reminder disabled.
await db.exec("update missions set active=false;update property_reminder_settings set schedules='[]';delete from property_message_recipients;delete from reminder_deliveries;delete from property_messages;delete from net.calls");
await db.exec(`insert into missions(id,title,property_id,due_at,target_employee_ids) values('${id(81)}','등록 즉시','${id(1)}','2030-03-06T00:00Z','["${id(21)}"]');`);
assert.equal((await q('select count(*)::int n from net.calls'))[0].n,1);
assert.deepEqual((await q('select employee_id from property_message_recipients')).map(x=>x.employee_id),[id(21)]);
await db.exec(`update missions set title='등록 후 수정' where id='${id(81)}'`);
assert.equal((await q('select count(*)::int n from net.calls'))[0].n,1,'editing does not resend creation alert');
await db.exec(`insert into calendar_events values('${id(82)}','새 일정','${id(1)}','2030-03-06T00:00Z',array['${id(22)}'::uuid],null);`);
assert.equal((await q('select count(*)::int n from net.calls'))[0].n,2,'calendar also alerts on registration');
await save([rule({offset_days:5}),rule({offset_days:1})],[rule({offset_days:5})]);
assert.equal(await run('2030-02-28T00:00Z'),0,'outside window');
for(let day=1;day<=6;day++){
 const date='2030-03-'+String(day).padStart(2,'0')+'T00:00Z';
 assert.equal(await run(date),2,`${day}: daily window includes both endpoints and overlapping rules coalesce`);
 assert.equal(await run(date),0,'retry idempotence');
}
assert.equal(await run('2030-03-07T00:00Z'),0,'stops after due date without overdue option');
// Old scheduler already sent today: migration must not send that item twice today.
await db.exec(`delete from reminder_deliveries where delivery_key='daily:2030-03-06';insert into reminder_deliveries(kind,item_id,offset_days,send_time,delivery_key,created_at) values('todo','${id(81)}',0,'09:00','','2030-03-06T00:00Z');`);
assert.equal(await run('2030-03-06T00:00Z'),1,'legacy todo delivery suppressed while unsent calendar proceeds');
console.log('PASS: settings validation/atomicity, legacy rules, daily overdue, completion/ending, check-in date and activation, per-worker delivery, owner dedupe, branch isolation, calendar and private ACL');
await db.close();
})().catch(e=>{console.error(e);process.exitCode=1;db.close();});
