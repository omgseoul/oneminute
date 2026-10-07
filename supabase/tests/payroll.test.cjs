const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {PGlite}=require('@electric-sql/pglite');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
test('payroll persists settings, scopes owners, calculates cycles, and protects salary data',async()=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema omg_private;
 create function omg_private.token_hash(uuid) returns text language sql as 'select $1::text';
 create table properties(id uuid primary key,name text,timezone text);
 create table owners(id uuid primary key,active boolean);
 create table owner_sessions(owner_id uuid,property_id uuid,login_token_hash text,token_expires_at timestamptz);
 create table employees(id uuid primary key,property_id uuid,display_name text,active boolean,role text,created_at timestamptz default now());
 create table property_share_requests(requester_property_id uuid,target_property_id uuid,status text,requested_permissions text[]);
 create table work_sessions(employee_id uuid,property_id uuid,work_date date,clock_in_at timestamptz,clock_out_at timestamptz,status text);
 create function omg_private.can_manage_shared_property(p_token uuid,p_property uuid,p_scope text) returns boolean language sql security definer set search_path='' as $$
 SELECT EXISTS(SELECT 1 FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_token) AND s.token_expires_at>clock_timestamp() AND o.active
 AND (s.property_id=p_property OR EXISTS(SELECT 1 FROM public.property_share_requests r WHERE r.requester_property_id=s.property_id AND r.target_property_id=p_property AND r.status='approved' AND p_scope=ANY(r.requested_permissions)))) $$;
 insert into properties values('${id(1)}','서울역','Asia/Seoul'),('${id(2)}','종로','Asia/Seoul');
 insert into owners values('${id(10)}',true);
 insert into owner_sessions values('${id(10)}','${id(1)}','${id(100)}',now()+interval '1 hour');
 insert into employees values('${id(11)}','${id(1)}','근무자 A',true,'staff',now()),('${id(12)}','${id(2)}','근무자 B',true,'staff',now());
 insert into work_sessions values
 ('${id(11)}','${id(1)}','2024-02-01','2024-02-01 09:00Z','2024-02-01 10:30Z','completed'),
 ('${id(11)}','${id(1)}','2024-02-29','2024-02-29 09:00Z','2024-02-29 10:01Z','completed'),
 ('${id(11)}','${id(1)}','2024-03-01','2024-03-01 09:00Z','2024-03-01 11:00Z','completed'),
 ('${id(11)}','${id(1)}','2024-02-15','2024-02-15 09:00Z',null,'needs_review');`);
 const root=path.join(__dirname,'../..');
 await db.exec(fs.readFileSync(path.join(root,'supabase/migrations/20261007081908_employee_payroll.sql'),'utf8'));
 const list=async(token=id(100),month='2024-02-01',ids=null)=>(await db.query('select public.list_employee_payroll($1,$2,$3) data',[token,month,ids])).rows[0].data;
 const settings={pay_type:'hourly',hourly_rate:10000,monthly_salary:2500000,cycle_start_day:1,pay_day:31,pay_month_offset:0};
 const save=async(s=settings,employee=id(11),token=id(100))=>(await db.query('select public.save_employee_payroll($1,$2,$3) data',[token,employee,s])).rows[0].data;
 let result=await list();assert.equal(result.employees.length,1);assert.equal(result.employees[0].expected_pay,null);assert.equal(result.employees[0].period_end,'2024-02-29');
 assert.equal((await save()).ok,true);
 result=(await list()).employees[0];assert.equal(result.work_minutes,151);assert.equal(result.expected_pay,25167);assert.equal(result.missing_count,1);assert.equal(result.work_days,2);assert.equal(result.pay_date,'2024-02-29');
 assert.equal((await list(id(999))).ok,false);assert.equal((await save(settings,id(11),id(999))).ok,false);
 assert.equal((await list(id(100),'2024-02-01',[id(2)])).ok,false);assert.equal((await save(settings,id(12))).ok,false);
 assert.equal((await list(id(100),'2024-02-01',[])).employees.length,0);
 await db.exec(`insert into property_share_requests values('${id(1)}','${id(2)}','approved',array['attendance']);`);
 assert.equal((await list(id(100),'2024-02-01',[id(2)])).ok,false);
 await db.exec(`update property_share_requests set requested_permissions=array['attendance','account_settings'];`);
 assert.equal((await save(settings,id(12))).ok,true);assert.equal((await list(id(100),'2024-02-01',[id(2)])).employees[0].employee_id,id(12));
 assert.equal((await save({...settings,cycle_start_day:26,pay_day:10,pay_month_offset:1})).ok,true);
 result=(await list()).employees[0];assert.equal(result.period_start,'2024-02-26');assert.equal(result.period_end,'2024-03-25');assert.equal(result.work_minutes,181);assert.equal(result.pay_date,'2024-04-10');
 result=(await list(id(100),'2026-12-01')).employees[0];assert.equal(result.period_end,'2027-01-25');assert.equal(result.pay_date,'2027-02-10');
 assert.equal((await save({...settings,pay_type:'monthly'})).ok,true);assert.equal((await list()).employees[0].expected_pay,2500000);
 assert.equal((await save({...settings,hourly_rate:0})).ok,true);assert.equal((await list()).employees[0].expected_pay,0);
 for(const bad of [{hourly_rate:-1},{hourly_rate:1.5},{cycle_start_day:29},{pay_day:0},{pay_day:32},{pay_type:'invalid'},{pay_month_offset:2},{monthly_salary:1000000001},{cycle_start_day:null}])assert.equal((await save({...settings,...bad})).ok,false);
 const security=(await db.query("select relrowsecurity from pg_class where relname='employee_payroll_settings'")).rows[0];assert.equal(security.relrowsecurity,true);
 assert.equal((await db.query("select has_table_privilege('anon','public.employee_payroll_settings','SELECT') allowed")).rows[0].allowed,false);
 await db.exec('set role anon');await assert.rejects(db.query('select * from public.employee_payroll_settings'));await db.exec('reset role');
 await db.exec(`update owner_sessions set token_expires_at=now()-interval '1 minute';`);assert.equal((await list()).ok,false);assert.equal((await save()).ok,false);
 }finally{await db.close();}
});
