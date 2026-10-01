// Disposable PostgreSQL tests; no live accounts or external services.
const {PGlite}=require('@electric-sql/pglite');
const {pgcrypto}=require('@electric-sql/pglite/contrib/pgcrypto');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..'),read=f=>fs.readFileSync(path.join(root,f),'utf8');
const db=new PGlite({extensions:{pgcrypto}});
let count=0;const check=(v,msg)=>{assert.ok(v,msg);count++;console.log('PASS '+msg);};
async function one(sql,args=[]){return(await db.query(sql,args)).rows[0];}
async function rpc(name,args){await db.exec('set role anon');try{return(await one(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).r;}finally{await db.exec('reset role');}}
(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role;grant usage on schema public to anon,authenticated;
 create schema auth;create table auth.users(id uuid primary key,email text not null);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;`);
 // Hosted pg_cron/net/Vault dispatch scheduling is outside this disposable chat RPC suite.
 for(const f of fs.readdirSync(path.join(root,'migrations')).filter(f=>f.endsWith('.sql')&&!f.endsWith('_guest_email_worker_vault.sql')).sort())await db.exec(read('migrations/'+f));

 await db.exec(read('setup/002_register_employee_pins.example.sql').replace(/PIN_([1-4])/g,'731482'));
 await db.exec(read('setup/007_create_owner.example.sql').replace(/OWNER_LOGIN_ID/g,'boss.test').replace(/OWNER_PIN_6_TO_8/g,'517394'));
 const owner=await rpc('start_owner_session',['boss.test','517394']);
 const staff=(await db.query("select id,property_id from public.employees where active and role<>'owner' order by id")).rows;
 const worker=await rpc('start_work_session',[staff[0].id,'731482']);

 const worker2=await rpc('start_work_session',[staff[1].id,'731482']);
 check(!(await rpc('work_report_inbox',['00000000-0000-0000-0000-000000000000'])).ok,'invalid token rejected');
 const cfg=await rpc('get_work_app_config',[owner.access_token]);
 const kinds=['text','numeric','counter','rooms','photo'];const fields=kinds.map((kind,i)=>({key:'custom_test_'+i,label:'Field '+i,kind,size:i%2?'half':'full',required:i===0}));
 const ec=Object.fromEntries(cfg.employees.map(e=>[e.employee_id,{...e.report_config,clock_in:['custom_test_4','custom_test_1']} ]));
 const saved=await rpc('save_property_settings',[owner.access_token,'Report test',['101','102'],ec,[{name:'Rooms',rooms:['101','102']}],'lodging',fields]);
 check(saved.ok&&saved.property.custom_report_fields.map(f=>f.kind).join()==kinds.join(),'all five kinds persist through actual settings RPC');
 check(saved.employees.find(e=>e.employee_id===staff[0].id).report_config.clock_in.join()==='custom_test_4,custom_test_1','selection order survives settings save');
 check(saved.property.custom_report_fields[0].required===true&&saved.property.custom_report_fields[1].size==='half','layout and required metadata survive settings save');
 const bad=await rpc('save_property_settings',[owner.access_token,'Report test',['101','102'],ec,[{name:'Rooms',rooms:['101','102']}],'lodging',[{key:'custom_bad',label:'Bad',kind:'script'}]]);
 check(!bad.ok,'unknown custom kind rejected');
 const badSize=await rpc('save_property_settings',[owner.access_token,'Report test',['101','102'],ec,[{name:'Rooms',rooms:['101','102']}],'lodging',[{key:'custom_bad',label:'Bad',kind:'text',size:'giant',required:true}]]);
 check(!badSize.ok,'invalid custom size rejected');
 const badRequired=await rpc('save_property_settings',[owner.access_token,'Report test',['101','102'],ec,[{name:'Rooms',rooms:['101','102']}],'lodging',[{key:'custom_bad',label:'Bad',kind:'text',size:'half',required:'yes'}]]);
 check(!badRequired.ok,'nonboolean required option rejected');
 const a=await rpc('save_work_report',[worker.access_token,'clock_in',{memo:'worker one',text:'Arrival'}]);
 const repeat=await rpc('save_work_report',[worker.access_token,'clock_in',{memo:'retry'}]);
 check(a.report_id===repeat.report_id,'delivery retry retains one report row');
 const b=await rpc('save_work_report',[worker2.access_token,'clock_in',{memo:'worker two'}]);
 const out=await rpc('save_work_report',[worker.access_token,'clock_out',{memo:'Leaving'}]);
 const own=await rpc('work_report_inbox',[worker.access_token]);
 check(own.reports.length===2&&own.reports.every(r=>r.employee_name===worker.employee_name),'staff sees only own arrival and departure as separate rows');
 check(own.reports.every(r=>r.payload===null),'list excludes large payload/photo data');
 const ownerInbox=await rpc('work_report_inbox',[owner.access_token]);check(ownerInbox.reports.length===3,'owner sees submitted reports from both workers');
 check(ownerInbox.unread_count===3&&ownerInbox.reports.every(r=>r.unread),'new reports count as unread for owner');
 check(own.unread_count===0&&own.reports.every(r=>!r.unread),'staff reports do not have owner unread badges');
 check(!(await rpc('mark_work_report_read',[worker.access_token,a.report_id])).ok,'staff cannot mark owner reports read');
 check((await rpc('mark_work_report_read',[owner.access_token,a.report_id])).ok,'owner can mark a visible report read');
 const afterRead=await rpc('work_report_inbox',[owner.access_token]);check(afterRead.unread_count===2&&afterRead.reports.find(r=>r.report_id===a.report_id).unread===false,'read receipt clears only opened report');
 check((await rpc('mark_work_report_read',[owner.access_token,a.report_id])).ok,'repeated report read is idempotent');
 check((await rpc('work_report_inbox',[worker.access_token,b.report_id])).reports.length===0,'staff cannot read another worker report by ID');
 const detail=await rpc('work_report_inbox',[worker.access_token,a.report_id]);check(detail.reports[0].payload.memo==='worker one','own report detail includes saved answers');
 const older=await rpc('work_report_inbox',[worker.access_token,null,own.reports[0].submitted_at,own.reports[0].report_id]);check(older.reports.length===1,'cursor pagination avoids repeating newest report');
 await db.query('update public.work_sessions set token_expires_at=now()-interval \'1 second\' where id=$1',[worker.session_id]);
 check(!(await rpc('work_report_inbox',[worker.access_token])).ok,'expired work token rejected');
 // Different property cannot be read without explicit message-sharing permission.
 const property=await one("insert into public.properties(business_id,name,code) select business_id,'Remote','remote-test' from public.properties where id=$1 returning id",[staff[0].property_id]);
 const employee=await one("insert into public.employees(business_id,property_id,display_name) select business_id,id,'Remote worker' from public.properties where id=$1 returning id",[property.id]);
 const work=await one("insert into public.work_sessions(business_id,property_id,employee_id,shift,login_token_hash) select business_id,property_id,id,'morning','unusable' from public.employees where id=$1 returning id",[employee.id]);
 const report=await one("insert into public.work_reports(work_session_id,business_id,property_id,employee_id,report_type) select id,business_id,property_id,employee_id,'clock_in' from public.work_sessions where id=$1 returning id",[work.id]);
 check((await rpc('work_report_inbox',[owner.access_token,report.id])).reports.length===0,'owner cannot read unshared property report');
 check(!(await rpc('mark_work_report_read',[owner.access_token,report.id])).ok,'owner cannot mark unshared report read');
 check((await rpc('work_report_inbox',[owner.access_token])).unread_count===2,'unshared report does not affect unread count');
 check((await one("select relrowsecurity r from pg_class where oid='public.work_reports'::regclass")).r,'reports table RLS remains enabled');
 console.log('PASS '+count+' report mailbox/config authorization checks');await db.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
