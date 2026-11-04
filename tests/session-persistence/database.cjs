const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs'),assert=require('node:assert/strict');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
(async()=>{
 const db=new PGlite();
 await db.exec(fs.readFileSync('tests/holiday-requests/schema.sql','utf8'));
 // Only the PIN hash primitive is substituted; all session decisions use real functions.
 await db.exec(`create table businesses(id uuid primary key,code text);
 create function omg_private.pin_matches(text,text) returns boolean language sql as 'select $1=$2';
 create function omg_private.session_result(p_id uuid) returns jsonb language sql as $$
 select jsonb_build_object('ok',true,'session_kind','staff','status',status,'session_id',id,'expires_at',token_expires_at) from public.work_sessions where id=p_id$$;
 create function public.evaluate_attendance_warnings(uuid,text) returns jsonb language sql as $$select '{}'::jsonb$$;
 alter table work_sessions add nfc_entry_at timestamptz;
 `);
 await db.exec(fs.readFileSync('tests/session-persistence/baseline.sql','utf8'));
 await db.exec('create role service_role');
 const guest=fs.readFileSync('supabase/migrations/034_guest_support.sql','utf8');
 await db.exec(guest.match(/create or replace function omg_private\.guest_actor\([\s\S]*?\$\$;/i)[0]);
 await db.exec(fs.readFileSync('supabase/migrations/037_native_push_devices.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/20261024111120_preserve_attendance_shift_across_midnight.sql','utf8'));
 // Match the existing privileges. Migration must not expand them.
 await db.exec(`revoke all on function omg_private.owner_session_result(uuid) from public,anon,authenticated;
 grant usage on schema public to anon;
 insert into businesses(id,code) values('${id(1)}','fixture');
 insert into properties(id,business_id,code,name,management_number)values('${id(2)}','${id(1)}','one','Fixture',1);
 insert into owners(id,business_id,property_id,display_name,login_id,pin_hash)values('${id(3)}','${id(1)}','${id(2)}','Owner','fixture-owner','123456');
 insert into employees(id,business_id,property_id,display_name,pin_hash)values('${id(4)}','${id(1)}','${id(2)}','Worker','123456');`);
 const rpc=async(name,args=[])=>{await db.exec('set role anon');try{return(await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) v`,args)).rows[0].v;}finally{await db.exec('reset role');}};
 const admin=()=>rpc('start_admin_session',[id(3),'123456','fixture','one']);
 const get=t=>rpc('get_app_session',[t]);
 const active=await admin(),expired=await admin(),revoked=await admin();
 assert(new Date(active.expires_at)-Date.now()<12*3600000+1000,'baseline reproduces 12-hour expiry');
 await db.query("update owner_sessions set token_expires_at=now()-interval '1 day' where id=$1",[expired.session_id]);
 await rpc('end_app_session',[revoked.access_token]);
 const staff=await rpc('start_work_session',[id(4),'123456','general','fixture','one']);
 const staffExpiry=staff.expires_at;
 const push=await rpc('register_native_push',[active.access_token,id(8),'f'.repeat(60)]);
 await db.exec(fs.readFileSync('supabase/migrations/20261104021109_persistent_owner_sessions.sql','utf8'));
 assert.equal((await get(active.access_token)).expires_at,'9999-12-31T23:59:59Z','existing active token persists and serializes for Android Instant.parse');
 assert.equal((await get(expired.access_token)).ok,false,'expired tokens never revived');
 assert.equal((await get(revoked.access_token)).ok,false,'explicit logout never revived');
 assert.equal((await get(staff.access_token)).expires_at,staffExpiry,'staff expiry unchanged');
 assert((await db.query("select expires_at='infinity'::timestamptz indefinite from native_push_devices where device_id=$1",[id(8)])).rows[0].indefinite,'existing push registration has no 12h deadline');
 const targets=async()=> (await db.query('select public.resolve_native_push_targets($1::text[]) v',[[push.topic]])).rows[0].v;
 assert.equal((await targets())[0].token,'f'.repeat(60),'persistent session can receive push');
 for(const session of [await admin(),await rpc('start_owner_session',['fixture-owner','123456','fixture','one'])]){
  assert.equal(session.expires_at,'9999-12-31T23:59:59Z');
  assert.equal((await db.query("select token_expires_at='infinity'::timestamptz indefinite from owner_sessions where id=$1",[session.session_id])).rows[0].indefinite,true);
  // Changing login age cannot end an administrator's session.
  await db.query("update owner_sessions set created_at=now()-interval '2 years' where id=$1",[session.session_id]);
  assert((await get(session.access_token)).ok);
  await rpc('end_app_session',[session.access_token]);assert.equal((await get(session.access_token)).ok,false);
 }
 const secondDevice=await admin();assert((await get(active.access_token)).ok,'second device does not revoke an owner');
 await db.query('update owners set active=false where id=$1',[id(3)]);
 assert.equal((await get(secondDevice.access_token)).ok,false,'disabled owner remains blocked');
 assert.equal((await targets())[0].token,null,'disabled owner receives no push');
 await db.query('update owners set active=true where id=$1',[id(3)]);
 assert.equal((await rpc('start_admin_session',[id(3),'123456','fixture','other'])).ok,false,'property cannot be forged');
 for(let i=0;i<5;i++)assert.equal((await rpc('start_admin_session',[id(3),'000000','fixture','one'])).ok,false);
 assert.equal((await admin()).code,'locked','PIN lockout retained');
 assert.equal((await get(id(99))).ok,false,'unknown token rejected');
 const relogin=await rpc('start_work_session',[id(4),'123456','general','fixture','one']);
 assert.equal((await get(staff.access_token)).ok,false,'staff re-login replaces previous token');
 assert.equal(relogin.session_id,staff.session_id);
 await db.query("update work_sessions set token_expires_at=now()-interval '1 second' where id=$1",[relogin.session_id]);
 assert.equal((await get(relogin.access_token)).ok,false,'staff 20-hour limit still enforced');
 const acl=(await db.query("select has_function_privilege('anon','omg_private.owner_session_result(uuid)','execute') helper")).rows[0];assert.equal(acl.helper,false,'private helper not exposed');
 await rpc('end_app_session',[active.access_token]);assert.equal((await targets())[0].token,null,'logout stops push even with infinite device expiry');
 await db.close();console.log('PASS: 12h reproduction, persistent admin/owner logins, active-session upgrade, no resurrection, logout, disabled accounts, tenant/PIN checks, multi-device owner, unchanged staff policy and private ACL');
})().catch(e=>{console.error(e);process.exitCode=1});
