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
 for(const f of fs.readdirSync(path.join(root,'migrations')).filter(f=>f.endsWith('.sql')).sort())await db.exec(read('migrations/'+f));
 await db.exec(read('migrations/032_attendance_login_warning_targets.sql'));
 check(true,'migration installs and can run twice');
 await db.exec(read('setup/002_register_employee_pins.example.sql').replace(/PIN_([1-4])/g,'731482'));
 await db.exec(read('setup/007_create_owner.example.sql').replace(/OWNER_LOGIN_ID/g,'boss.test').replace(/OWNER_PIN_6_TO_8/g,'517394'));
 const owner=await rpc('start_owner_session',['boss.test','517394']);check(owner.ok,'owner login works');
 const staff=(await db.query('select id from public.employees where active and role<>\'owner\' order by id')).rows;
 const ids=staff.map(s=>s.id),token=owner.access_token;
 await db.exec("update public.employees set scheduled_clock_in='12:00',scheduled_clock_out='20:00'");
 const base={employee_ids:ids.slice(0,2),target_all:false,event_type:'clock_in',comparison:'both',threshold_minutes:0,message:'{이름} / {예정시간} / {실제시간} / {차이분}',active:true};
 let result=await rpc('save_attendance_warning_rules',[token,JSON.stringify([base])]);check(result.ok&&result.rules[0].employee_ids.length===2,'multiple targets save and reload');
 const rule=result.rules[0];
 const first=await rpc('start_work_session',[ids[0],'731482']);check(first.ok&&first.warning_message_ids.length===1,'first login sends warning before report');
 const msg=await one('select * from public.property_messages where id=$1',[first.warning_message_ids[0]]);check(msg.message_type==='attendance_warning'&&msg.sender_type==='system','warning has separate attendance type');
 check(!(await one('select checkin_report_at from public.work_sessions where id=$1',[first.session_id])).checkin_report_at,'no check-in report was needed');
 const again=await rpc('start_work_session',[ids[0],'731482']);check(again.warning_message_ids.length===0,'same-day re-login sends no duplicate');
 check((await rpc('evaluate_attendance_warnings',[again.access_token,'clock_in'])).message_ids.length===0,'check-in report does not send arrival warning');
 const outsider=await rpc('start_work_session',[ids[2],'731482']);check(outsider.warning_message_ids.length===0,'unselected employee gets no warning');
 let all=await rpc('save_attendance_warning_rules',[token,JSON.stringify([{...rule,target_all:true,employee_ids:[]}])]);check(all.ok&&all.rules[0].target_all,'All saves as dynamic whole-property target');
 const next=await rpc('start_work_session',[ids[3],'731482']);check(next.warning_message_ids.length===1,'All includes another employee');
 const bad=await rpc('save_attendance_warning_rules',[token,JSON.stringify([{...rule,message:'must roll back'},{...base,employee_ids:['00000000-0000-4000-8000-000000000099']}])]);
 check(!bad.ok,'unknown or foreign target is rejected');
 check((await rpc('list_attendance_warning_rules',[token])).rules[0].message===base.message,'invalid batch rolls back earlier edits');
 const list=await rpc('list_property_messages',[again.access_token]);check(list.messages.some(m=>m.message_type==='attendance_warning'&&m.sender_label==='근태관리'),'inbox uses attendance sender');
 const readAttempt=await rpc('mark_property_message_read',[again.access_token,msg.id]);check(readAttempt.code==='acknowledgement_required','attendance warning retains explicit acknowledgement');
 const name=(await one('select display_name from public.employees where id=$1',[ids[0]])).display_name;
 check(!(await rpc('acknowledge_announcement',[again.access_token,msg.id,'wrong',true])).ok,'wrong acknowledgement name rejected');
 check((await rpc('acknowledge_announcement',[again.access_token,msg.id,name,true])).ok,'attendance warning acknowledgement works');
 check(!(await rpc('save_attendance_warning_rules',[again.access_token,'[]'])).ok,'staff cannot edit rules');
 // Simulate a prior local day, then verify a new-day login can notify again.
 await db.query("update public.attendance_login_checks set login_date=login_date-1 where employee_id=$1",[ids[0]]);
 await db.query("update public.work_sessions set work_date=work_date-1,created_at=created_at-interval '1 day',clock_in_at=clock_in_at-interval '1 day' where employee_id=$1",[ids[0]]);
 const tomorrow=await rpc('start_work_session',[ids[0],'731482']);check(tomorrow.warning_message_ids.length===1,'next local day can send a new arrival warning');
 const durationRules=['clock_out','work_duration'].map(event_type=>({...base,employee_ids:[ids[0]],event_type,comparison:'late',threshold_minutes:10}));
 check((await rpc('save_attendance_warning_rules',[token,JSON.stringify(durationRules)])).ok,'checkout and duration rules save');
 await db.query("update public.work_sessions set clock_in_at=(work_date+time '12:00') at time zone 'Asia/Seoul',clock_out_at=(work_date+time '21:00') at time zone 'Asia/Seoul',status='completed' where id=$1",[tomorrow.session_id]);
 const checkout=await rpc('evaluate_attendance_warnings',[tomorrow.access_token,'clock_out']);check(checkout.message_ids.length===2,'late checkout and excess duration both send attendance warnings');
 check((await rpc('evaluate_attendance_warnings',[tomorrow.access_token,'clock_out'])).message_ids.length===0,'repeated checkout evaluation does not duplicate');
 // Push delivery leases and routing use the same disposable database fixtures.
 await db.exec(read('migrations/033_supabase_push_delivery.sql'));
 const claim=(await one("select public.claim_push_delivery('test-key') r")).r;
 check(claim.claimed,'first push obtains delivery lease');
 check(!(await one("select public.claim_push_delivery('test-key') r")).r.claimed,'concurrent retry cannot claim active lease');
 check(!(await one("select public.finish_push_delivery('test-key',gen_random_uuid(),true) r")).r.ok,'wrong lease cannot mark delivery sent');
 await one("select public.finish_push_delivery('test-key',$1,false)",[claim.lease_id]);
 const retry=(await one("select public.claim_push_delivery('test-key') r")).r;
 check(retry.claimed,'rejected push can retry');
 await one("select public.finish_push_delivery('test-key',$1,true)",[retry.lease_id]);
 check((await one("select public.claim_push_delivery('test-key') r")).r.status==='sent','successful push never reclaims');
 await one("select public.claim_push_delivery('expired')");
 await db.exec("update public.push_delivery_attempts set lease_until=clock_timestamp()-interval '1 second' where delivery_key='expired'");
 check((await one("select public.claim_push_delivery('expired') r")).r.claimed,'expired ambiguous delivery can retry');
 let denied=false;try{await rpc('claim_push_delivery',['forbidden']);}catch(e){denied=e.code==='42501';}
 check(denied,'public client cannot create delivery leases');
 check(!(await one("select public.get_message_push_dispatch_v2(gen_random_uuid(),$1) r",[msg.id])).r.ok,'invalid session cannot resolve recipients');
 const dispatch=(await one("select public.get_message_push_dispatch_v2($1,$2) r",[tomorrow.access_token,tomorrow.warning_message_ids[0]])).r;
 check(dispatch.ok&&dispatch.recipient_topics.some(t=>t.endsWith('_employee_'+ids[0])),'attendance alert resolves authorized recipient topic');
 console.log(`${count} attendance warning checks passed`);await db.close();
})().catch(async e=>{console.error(e.message,e.detail||'');await db.close();process.exitCode=1;});
