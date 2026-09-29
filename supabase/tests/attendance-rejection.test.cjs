const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {PGlite}=require('@electric-sql/pglite');
const root=path.join(__dirname,'../..');
test('rejection preserves attendance, permits resubmission, scopes owners, and keeps one latest row',async()=>{
 const db=new PGlite();const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
 try{
 await db.exec(`set timezone to 'UTC';create role anon;create role authenticated;create schema omg_private;
 create function omg_private.token_hash(uuid) returns text language sql as 'select $1::text';
 create table properties(id uuid primary key,name text,timezone text);
 create table owners(id uuid primary key,property_id uuid,active boolean);
 create table owner_sessions(owner_id uuid,property_id uuid,login_token_hash text,token_expires_at timestamptz);
 create table employees(id uuid primary key,property_id uuid,active boolean,display_name text,role text,created_at timestamptz default now());
 create table work_sessions(id uuid primary key,business_id uuid,property_id uuid,employee_id uuid,work_date date,clock_in_at timestamptz,clock_out_at timestamptz,status text,login_token_hash text,token_expires_at timestamptz,checkin_report_at timestamptz,checkout_report_at timestamptz,unique(id,business_id,property_id,employee_id));
 create table property_share_requests(requester_property_id uuid,target_property_id uuid,status text,requested_permissions text[]);
 create table property_messages(id uuid primary key default gen_random_uuid(),business_id uuid,property_id uuid,sender_type text,sender_employee_id uuid,message text,priority text,message_type text,attendance_request_id uuid);
 create table property_message_recipients(message_id uuid,recipient_key text,recipient_type text,owner_id uuid,read_at timestamptz);
 create table urgent_messages(attendance_request_id uuid,acknowledged_at timestamptz,acknowledged_by uuid);
 `);
 const old=fs.readFileSync(path.join(root,'supabase/migrations/021_attendance_adjustment_approval.sql'),'utf8');
 await db.exec(old.slice(old.indexOf('create table'),old.indexOf('create index')));
 await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/047_attendance_rejection.sql'),'utf8'));
 await db.exec(`insert into properties values('${id(1)}','Test','Asia/Seoul'),('${id(2)}','Other','Asia/Seoul');insert into owners values('${id(3)}','${id(1)}',true),('${id(4)}','${id(2)}',true);insert into owner_sessions values('${id(3)}','${id(1)}','${id(5)}',now()+interval '1 day'),('${id(4)}','${id(2)}','${id(6)}',now()+interval '1 day');insert into employees(id,property_id,active,display_name,role) values('${id(7)}','${id(1)}',true,'Worker','staff');insert into work_sessions(id,business_id,property_id,employee_id,work_date,clock_in_at,clock_out_at,status,login_token_hash,token_expires_at) values('${id(8)}','${id(9)}','${id(1)}','${id(7)}','2026-09-29','2026-09-29 00:00Z','2026-09-29 08:00Z','completed','${id(10)}',now()+interval '1 day');`);
 const call=async(name,args)=>(await db.query(`select public.${name}(${args}) as result`)).rows[0].result;
 const request=()=>call('request_attendance_adjustment',`'${id(10)}','${id(8)}','09:00','18:00'`);
 let first=await request();assert(first.ok);
 assert.equal((await request()).code,'already_requested');
 assert.equal((await call('reject_attendance_adjustment',`'${id(6)}','${first.request_id}'`)).ok,false);
 assert.equal((await call('reject_attendance_adjustment',`'${id(5)}','${first.request_id}'`)).status,'rejected');
 assert.equal((await call('approve_attendance_adjustment',`'${id(5)}','${first.request_id}'`)).ok,false);
 assert.equal((await db.query('select clock_out_at::text as t from work_sessions')).rows[0].t,'2026-09-29 08:00:00+00');
 let second=await request();assert(second.ok);assert.notEqual(second.request_id,first.request_id);
 let stats=await call('list_attendance_statistics',`'${id(10)}','2026-09-29','2026-09-29'`);assert.equal(stats.sessions.length,1);assert.equal(stats.sessions[0].adjustment_status,'pending');
 assert.equal((await call('approve_attendance_adjustment',`'${id(5)}','${second.request_id}'`)).status,'approved');
 assert.equal((await call('reject_attendance_adjustment',`'${id(5)}','${second.request_id}'`)).ok,false);
 assert((await call('owner_update_attendance',`'${id(5)}','${id(8)}','10:00','19:00'`)).ok);
 assert.equal((await db.query('select status from attendance_adjustment_requests where id=$1',[first.request_id])).rows[0].status,'rejected');
 }finally{await db.close();}
});
