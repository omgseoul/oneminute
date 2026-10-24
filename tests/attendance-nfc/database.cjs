const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite();await db.exec(fs.readFileSync('tests/holiday-requests/schema.sql','utf8'));
 await db.exec(`create role service_role;alter table properties add constraint properties_clock_in_basis_check check(clock_in_basis in('first_login','report'));
 create table work_reports(id uuid primary key,work_session_id uuid,business_id uuid,property_id uuid,employee_id uuid,report_type text,payload jsonb,submitted_at timestamptz,make_accepted_at timestamptz,unique(work_session_id,report_type));
 create function omg_private.can_manage_shared_property(token uuid,property uuid,scope text) returns boolean language sql as $$select exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(token) and o.active and s.token_expires_at>clock_timestamp() and(s.property_id=property or exists(select 1 from public.property_share_requests r where r.requester_property_id=s.property_id and r.target_property_id=property and r.status='approved' and scope=any(r.requested_permissions))))$$;
 alter table work_sessions add check(clock_out_at is null or clock_out_at>=clock_in_at);`);
 await db.exec(fs.readFileSync('supabase/migrations/20261024105646_attendance_nfc_report_offset.sql','utf8'));
 const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
 const own=id(1),staff=id(2),p1=id(3),p2=id(4),employee=id(5),s1=id(6),owner=id(7);
 await db.query(`insert into properties(id,name)values($1,'Own'),($2,'Other');`,[p1,p2]);
 await db.query('insert into owners(id,active)values($1,true)',[owner]);
 await db.query("insert into owner_sessions(owner_id,property_id,login_token_hash,token_expires_at)values($1,$2,omg_private.token_hash($3),'infinity')",[owner,p1,own]);
 await db.query('insert into employees(id,property_id,display_name)values($1,$2,\'Test\')',[employee,p1]);
 await db.query("insert into work_sessions(id,employee_id,property_id,shift,login_token_hash,token_expires_at,clock_in_at)values($1,$2,$3,'general',omg_private.token_hash($4),'infinity',clock_timestamp()-interval '2 hours')",[s1,employee,p1,staff]);
 async function rpc(name,args){await db.exec('set role anon');try{return (await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;}finally{await db.exec('reset role');}}
 const settings=(basis,offset=0,tags=[])=>({basis,report_offset_minutes:offset,nfc_tags:tags});
 const save=(data,token=own,property=p1)=>rpc('attendance_clock_in_settings',[token,'save',property,JSON.stringify(data)]);
 assert.equal((await save(settings('nfc',0,['04:11:22:33:44:55:66']))).nfc_tags[0],'04112233445566');
 assert.equal((await save(settings('report'),staff)).ok,false,'staff cannot change settings');
 assert.equal((await save(settings('report'),own,p2)).ok,false,'unshared branch forbidden');
 assert.equal((await save(settings('nfc'))).ok,false,'empty NFC cannot lock workers out');
 assert.equal((await save(settings('report',1.5))).ok,false);
 assert.equal((await save(settings('report',1441))).ok,false);
 assert.equal((await save(settings('nfc',0,['not-a-tag']))).ok,false);
 assert.equal((await rpc('attendance_nfc_entry',[id(99),null])).ok,false);
 assert.equal((await rpc('save_work_report',[staff,'clock_in','{}'])).code,'nfc_required');
 assert.equal((await rpc('attendance_nfc_entry',[staff,'DEADBEEF'])).code,'wrong_tag');
 const first=await rpc('attendance_nfc_entry',[staff,'04112233445566']);assert(first.entry_at);assert(!first.checkin_report_at);assert(!first.already_recorded);
 const again=await rpc('attendance_nfc_entry',[staff,'04-11-22-33-44-55-66']);assert.equal(again.entry_at,first.entry_at);assert(again.already_recorded);
 const report=await rpc('save_work_report',[staff,'clock_in',JSON.stringify({attendance_clock_in_at:'2000-01-01',text:'제목\n출근시각: 잘못된 시각\n내용'})]);assert(report.ok);assert.equal(new Date(report.payload.attendance_clock_in_at).getTime(),new Date(first.entry_at).getTime());assert(!report.payload.text.includes('잘못된'));assert.equal(report.payload.attendance_basis,'nfc');
 const repeated=await rpc('save_work_report',[staff,'clock_in','{}']);assert(repeated.already_saved);assert.equal(repeated.report_id,report.report_id);
 await db.query("update work_sessions set status='completed',clock_out_at=clock_timestamp() where id=$1",[s1]);assert(!(await rpc('attendance_nfc_entry',[staff,'04112233445566'])).ok);
 // Separate shifts never inherit entry timestamps. Reset only this isolated fixture.
 await db.exec('truncate work_reports');await db.query("update work_sessions set status='working',checkin_report_at=null,clock_out_at=null,nfc_entry_at=null,nfc_tag_uid=null where id=$1",[s1]);
 for(const offset of [-10,0,10]){
  assert((await save(settings('report',offset))).ok);
  const result=await rpc('save_work_report',[staff,'clock_in','{}']);assert(result.ok);
  assert.equal(new Date(result.payload.attendance_clock_in_at)-new Date(result.payload.submitted_at),offset*60000);
  if(offset>0)assert.equal((await rpc('save_work_report',[staff,'clock_out','{}'])).code,'before_clock_in');
  await db.exec('truncate work_reports');await db.query('update work_sessions set checkin_report_at=null where id=$1',[s1]);
 }
 assert((await save(settings('first_login'))).ok);const before=(await db.query('select clock_in_at from work_sessions where id=$1',[s1])).rows[0].clock_in_at;
 const loginReport=await rpc('save_work_report',[staff,'clock_in','{}']);assert.equal(new Date(loginReport.payload.attendance_clock_in_at).getTime(),new Date(before).getTime());
 await db.query("insert into property_share_requests(requester_property_id,target_property_id,requested_permissions,status)values($1,$2,array['property_settings'],'approved')",[p1,p2]);assert((await save(settings('report',-10),own,p2)).ok);
 await db.query('update owners set active=false where id=$1',[owner]);assert(!(await save(settings('report'))).ok);
 const access=(await db.query("select has_function_privilege('anon','public.attendance_nfc_entry(uuid,text)','execute') allowed,has_function_privilege('anon','omg_private.normalize_attendance_uid(text)','execute') helper")).rows[0];assert(access.allowed);assert(!access.helper);
 await db.close();console.log('PASS: owner/shared authorization, UID normalization, missing/wrong/repeated NFC, server timestamps, idempotent reports, offsets -10/0/+10, completed shifts, privileges');
})().catch(error=>{console.error(error);process.exitCode=1});
