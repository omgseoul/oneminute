const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const {PGlite}=require('@electric-sql/pglite');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
test('account salary saves are exclusive, preserve cycle, and document access is private',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema omg_private;create schema storage;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit integer,allowed_mime_types text[]);
 create table employees(id uuid primary key,property_id uuid,role text);
 create table employee_payroll_settings(employee_id uuid primary key,pay_type text,hourly_rate integer,monthly_salary integer,cycle_start_day integer default 1,pay_day integer,pay_month_offset integer default 1,updated_at timestamptz);
 create function omg_private.can_manage_shared_property(t uuid,p uuid,s text) returns boolean language sql as $$select t='${id(100)}'::uuid and p='${id(1)}'::uuid and s='account_settings'$$;
 insert into employees values('${id(11)}','${id(1)}','staff'),('${id(12)}','${id(2)}','staff');
 insert into employee_payroll_settings values('${id(11)}','monthly',null,3000000,26,10,1,now());`);
 await db.exec(fs.readFileSync('supabase/migrations/20261007154441_account_pay_and_documents.sql','utf8'));
 const save=async(a,b,employee=id(11),token=id(100))=>(await db.query('select save_employee_account_pay($1,$2,$3,$4) result',[token,employee,a,b])).rows[0].result;
 assert.equal((await save(12000,3000000)).ok,false);assert.equal((await save(-1,null)).ok,false);assert.equal((await save(12000,null,id(12))).ok,false);assert.equal((await save(12000,null,id(11),id(999))).ok,false);
 assert.equal((await save(12000,null)).ok,true);
 let row=(await db.query('select * from employee_payroll_settings')).rows[0];assert.equal(row.hourly_rate,12000);assert.equal(row.monthly_salary,null);assert.equal(row.cycle_start_day,26);assert.equal(row.pay_day,10);
 assert.equal((await save(null,3000000)).ok,true);row=(await db.query('select * from employee_payroll_settings')).rows[0];assert.equal(row.hourly_rate,null);assert.equal(row.pay_type,'monthly');
 assert.equal((await save(null,null)).ok,true);
 assert.equal((await db.query('select authorize_employee_documents($1,$2) prop',[id(100),id(11)])).rows[0].prop,id(1));
 assert.equal((await db.query('select authorize_employee_documents($1,$2) prop',[id(100),id(12)])).rows[0].prop,null);
 assert.equal((await db.query("select has_function_privilege('anon','authorize_employee_documents(uuid,uuid)','execute') allowed")).rows[0].allowed,false);
 assert.equal((await db.query("select has_table_privilege('anon','employee_documents','select') allowed")).rows[0].allowed,false);
 assert.equal((await db.query("select relrowsecurity from pg_class where relname='employee_documents'")).rows[0].relrowsecurity,true);
 assert.equal((await db.query('select public from storage.buckets')).rows[0].public,false);
 }finally{await db.close();}
});
