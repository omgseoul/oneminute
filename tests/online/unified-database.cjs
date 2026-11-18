const fs=require('node:fs'),assert=require('node:assert/strict');
module.exports=async({db,owner,internal,p1,p2,t1,t2,id})=>{
 // The broad suite uses a bot placeholder. Feed filtering itself is exercised by notification-bot-db.
 await db.exec(`create or replace function public.list_notification_bot_messages(uuid,timestamptz,uuid)returns jsonb language sql as $$select jsonb_build_object('ok',true,'messages',coalesce(jsonb_agg(m.id),'[]')) from public.property_messages m where (m.sender_type='system' or m.message_type in('announcement'))$$;`);
 const sql=fs.readFileSync('supabase/setup/beds24_unified_guest_messages.sql','utf8');await db.exec(sql);await db.exec(sql);await db.exec(fs.readFileSync('supabase/setup/beds24_guest_message_summary.sql','utf8'));
 const employee=id(98001),token=id(98002),room=id(98003),other=id(98004);
 await db.query("insert into employees(id,property_id,display_name)values($1,$2,'Synthetic worker')",[employee,p1]);
 await db.query("insert into work_sessions(employee_id,property_id,login_token_hash,token_expires_at,status)values($1,$2,omg_private.token_hash($3),'infinity','working')",[employee,p1,token]);
 const worker=(action,data={})=>owner(action,data,token);
 const auth=await worker('auth',{request_action:'send'});assert.equal(auth.kind,'staff');
 for(const request_action of ['settings','connect','properties','save_settings','translation_status','save_auto_translation'])await assert.rejects(()=>worker('auth',{request_action}),/관리자 설정/);
 for(const action of ['settings','save_settings','save_auto_translation','webhook_logs'])await assert.rejects(()=>worker(action),/관리자 설정/);
 const cfg=await worker('guest_settings');assert(cfg.branches.some(p=>p.id===p1));assert(!('webhook_key'in cfg));assert(!('translation_vault_id'in cfg));assert(!('connection_sources'in cfg));
 assert((await worker('inbox')).threads.length);await assert.rejects(()=>worker('inbox',{property_id:p2}),/권한/);
 await assert.rejects(()=>worker('prepare_send',{id:id(98005),booking_id:10000000,body:'Hello'}),/예약정보/);
 const send=await worker('prepare_send',{id:id(98005),booking_id:10,body:'Synthetic response'});assert(send.ok);assert.equal((await worker('prepare_send',{id:id(98005),booking_id:10,body:'Synthetic response'})).skip,true);
 await db.query("insert into guest_chat_rooms(id,property_id,guest_name,check_in,check_out,room_number,token_hash,expires_at,ip_hash)values($1,$2,'QR Guest',current_date,current_date+1,'401','synthetic-qr-a','infinity','fixture'),($3,$4,'Other Guest',current_date,current_date+1,'402','synthetic-qr-b','infinity','fixture')",[room,p1,other,p2]);
 await db.query("insert into guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body,created_at)values($1,$2,'guest:fixture','Guest','guest','Question',now()-interval '1 minute'),($3,$4,'guest:other','Guest','guest','Private',now())",[room,id(98006),other,id(98007)]);
 const inbox=async(data={},t=token)=>(await db.query('select public.guest_message_inbox($1,$2) v',[t,JSON.stringify(data)])).rows[0].v;
 await db.exec('set role anon');await assert.rejects(()=>inbox({},id(98099)),/로그인/);assert.equal((await inbox()).threads.length,1);assert((await db.query('select public.guest_message_unread($1) v',[token])).rows[0].v.ok);await db.exec('reset role');
 let rows=(await inbox()).threads;assert.equal(rows.length,1);assert.equal(rows[0].status,'qr');assert.equal(rows[0].unread,1);assert(!rows[0].replied);assert.equal(rows[0].room_name,'401');
 const summary=async(data={},t=token)=>(await db.query('select public.guest_message_summary($1,$2) v',[t,JSON.stringify({filters:{version:1,qrVersion:1,statuses:data.statuses,direction:data.direction,stayTypes:data.stay_types,unreadOnly:data.unread_only,unrepliedOnly:data.unreplied_only,properties:data.properties},period:{days:0,from:data.message_from||'1900-01-01',to:data.message_to||'2100-01-01'}})])).rows[0].v;
 // A self-addressed popup test must not become an invisible unread conversation.
 const fixedSummary=fs.readFileSync('supabase/setup/beds24_guest_message_summary.sql','utf8');
 await db.exec(fixedSummary.replace(" and (case m.sender_type when 'owner' then 'owner:'||m.sender_owner_id when 'staff' then 'employee:'||m.sender_employee_id else '' end) is distinct from a->>'key'",''));
 const selfFix=fs.readFileSync('supabase/migrations/20261118110000_staff_unread_exclude_self.sql','utf8');await db.exec(selfFix);await db.exec(selfFix);
 await db.exec('begin');
 for(const [actorToken,kind,n] of [[t1,'owner',98100],[t2,'owner',98110],[token,'staff',98120]]){
  const actor=(await db.query('select omg_private.guest_actor($1) a',[actorToken])).rows[0].a;
  const baseline=(await summary({},actorToken)).messenger_unread;
  const mid=id(n),incoming=id(n+1),system=id(n+2),senderColumn=kind==='owner'?'sender_owner_id':'sender_employee_id',recipientColumn=kind==='owner'?'owner_id':'employee_id';
  await db.query(`insert into property_messages(id,property_id,sender_type,${senderColumn},message,message_type,source)values($1,$2,$3,$4,'Synthetic self popup','general','oms_popup_test')`,[mid,actor.property_id,kind,actor.id]);
  await db.query(`insert into property_message_recipients(message_id,recipient_key,recipient_type,${recipientColumn})values($1,$2,$3,$4)`,[mid,actor.key,kind,actor.id]);
  assert.equal((await summary({},actorToken)).messenger_unread,baseline,'self-sent messages are not unread for owners or workers in any property');
  const otherOwner=(await db.query('select omg_private.guest_actor($1) a',[actorToken===t1?t2:t1])).rows[0].a;
  await db.query("insert into property_messages(id,property_id,sender_type,sender_owner_id,message,message_type)values($1,$2,'owner',$3,'Incoming message','general'),($4,$2,'system',null,'System reminder','general')",[incoming,actor.property_id,otherOwner.id,system]);
  for(const message of [incoming,system])await db.query(`insert into property_message_recipients(message_id,recipient_key,recipient_type,${recipientColumn})values($1,$2,$3,$4)`,[message,actor.key,kind,actor.id]);
  assert.equal((await summary({},actorToken)).messenger_unread,baseline+2,'incoming and system messages remain counted');
  assert.equal((await db.query('select read_at from property_message_recipients where message_id=$1',[mid])).rows[0].read_at,null,'fix must not mark the source message read');
 }
 await db.exec('rollback');
 await db.exec('set role anon');assert.equal((await summary({statuses:['qr']})).unread,1);await assert.rejects(()=>summary({},id(98099)),/로그인/);await db.exec('reset role');
 for(const filters of [{},{statuses:['confirmed']},{statuses:['qr']},{statuses:[]},{direction:'host'},{unreplied_only:true},{unread_only:true},{stay_types:['other']},{message_from:'2000-01-01',message_to:'2000-01-02'}]){
  const online=(await worker('inbox',{...filters,statuses:filters.statuses?.filter(x=>x!=='qr')})).threads;
  const qr=!filters.statuses||filters.statuses.includes('qr')?(await inbox(filters)).threads:[];
  const expected=[...online,...qr].reduce((sum,row)=>sum+row.unread,0);
  assert.equal((await summary(filters)).unread,expected,JSON.stringify(filters));
 }
 await db.exec('begin');
 await db.query("insert into omg_private.online_bookings(property_id,id,guest_name,status,data) select $1,9890000+n,'Page fixture','black','{}' from generate_series(1,301)n",[p1]);
 await db.query("insert into omg_private.online_messages(property_id,id,booking_id,source,body,sent_at) select $1,9890000+n,9890000+n,'guest','Fixture',now() from generate_series(1,301)n",[p1]);
 const paged=await summary({statuses:['black']});assert.equal(paged.unread,301);assert.equal(paged.threads,301,'count includes the second page');
 await db.exec('rollback');
 assert.equal((await summary({properties:[]})).unread,0,'no selected branches gives zero');
 assert.equal((await summary({properties:[p2]})).unread,(await summary()).unread,'revoked branch falls back to home without leaking other messages');
 assert.equal((await summary({statuses:['qr'],message_from:'2000-01-01',message_to:'2000-01-02'})).unread,0);
 assert((await summary({statuses:[]})).total_unread>0,'native all-scope badge is preserved separately');
 await assert.rejects(()=>inbox({property_id:p2}),/권한/);await assert.rejects(()=>inbox({},id(98099)),/로그인/);
 assert.equal((await inbox({message_from:'2000-01-01',message_to:'2000-01-02'})).threads.length,0);
 await db.query("insert into guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values($1,$2,$3,'Worker','staff','Response')",[room,id(98008),'employee:'+employee]);
 rows=(await inbox({direction:'guest'})).threads;assert.equal(rows[0].preview,'Question');assert(rows[0].replied);assert.equal((await inbox({direction:'host'})).threads[0].preview,'Response');assert.equal((await inbox({unreplied_only:true})).threads.length,0);
 await db.query("insert into guest_chat_reads(room_id,actor_key,last_seq)values($1,$2,999999)",[room,'employee:'+employee]);assert.equal((await inbox({unread_only:true})).threads.length,0);
 assert.equal((await summary({statuses:['qr']})).unread,0,'read cursor immediately reduces home count');
 await db.query("update property_share_requests set status='approved',requested_permissions=array['messages'] where requester_property_id=$1 and target_property_id=$2",[p1,p2]);
 assert.equal((await owner('auth',{property_id:p2,request_action:'inbox'})).property_id,p2);
 await assert.rejects(()=>owner('auth',{property_id:p2,request_action:'connect'}),/관리자 설정/);
 await assert.rejects(()=>owner('auth',{property_id:p2,request_action:'properties'}),/관리자 설정/);
 assert.equal((await worker('auth',{property_id:p2,request_action:'inbox'})).property_id,p2);
 assert.equal((await summary({properties:[p2],statuses:['qr']})).unread,1,'approved branch is counted');
 await db.query("update property_share_requests set status='revoked'");
 await db.query("update work_sessions set token_expires_at=now()-interval '1 minute' where employee_id=$1",[employee]);await assert.rejects(()=>worker('inbox'),/로그인/);await assert.rejects(()=>inbox(),/로그인/);
 await assert.rejects(()=>summary(),/로그인/);
 console.log('Unified inbox DB: QR filters/reply state, own/shared property isolation, revoked sessions, worker reply idempotency and settings secrecy passed');
};
