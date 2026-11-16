const fs=require('fs'),assert=require('node:assert/strict');
module.exports=async({db,rpc,call,q,id,o,s1,s2,peer1,g})=>{
 await db.exec(fs.readFileSync('supabase/setup/staff_chat_compact.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/staff_chat_compact.sql','utf8'));
 const compact=(t,a,d)=>rpc('staff_chat_compact',[t,a,d]);
 const photo='data:image/jpeg;base64,'+Buffer.concat([Buffer.from([255,216,255]),Buffer.alloc(100000)]).toString('base64'),preview='data:image/jpeg;base64,/9j/AA==';
 for(const peer of [peer1,g]){
  const sent=await compact(o,'send',{peer,body:'preview test',photo,preview,client_id:crypto.randomUUID()});
  const full=(await call(o,'messages',{peer})).messages.find(m=>m.id===sent.message_id);
  const small=(await compact(o,'messages',{peer})).messages.find(m=>m.id===sent.message_id);
  assert.equal(full.photo,photo,'legacy API unchanged');assert.equal(small.photo,preview);assert.equal(small.photo_is_preview,true);
  assert(JSON.stringify(small).length<JSON.stringify(full).length/20);
  assert.equal((await compact(o,'preview',{peer,message_id:sent.message_id})).preview,preview);
  await assert.rejects(()=>compact(id(88888),'preview',{peer,message_id:sent.message_id}),/로그인/);
  await assert.rejects(()=>compact(s2,'preview',{peer:peer1,message_id:sent.message_id}));
 }
 await assert.rejects(()=>compact(o,'send',{peer:peer1,body:'invalid',photo,preview:'data:image/jpeg;base64,AAAA',client_id:crypto.randomUUID()}),/미리보기/);
 await db.exec(`create table public.work_reports(id uuid primary key,property_id uuid,employee_id uuid,submitted_at timestamptz,report_type text,payload jsonb);
 create table omg_private.report_inbox_started(id boolean,started_at timestamptz);insert into omg_private.report_inbox_started values(true,'2000-01-01');
 create table omg_private.work_report_reads(report_id uuid,owner_id uuid);
 create function omg_private.guest_popup_online(uuid,uuid)returns jsonb language sql as $$select to_jsonb(current_setting('test.popup',true))$$;
 create function omg_private.guest_can_access(uuid,uuid)returns boolean language sql as $$select $1=$2$$;
 create function omg_private.guest_message_summary(uuid,jsonb)returns jsonb language sql as $$select jsonb_build_object('ok',true,'unread',7,'messenger_unread',(select count(*) from public.property_message_recipients where recipient_key=omg_private.guest_actor($1)->>'key' and read_at is null))$$;
 `);
 await db.exec(fs.readFileSync('supabase/setup/home_message_summary.sql','utf8'));
 const summary=(token,rev=null,alerts=false)=>rpc('home_message_summary',[token,{},rev,alerts]);
 assert.equal((await summary(id(88888))).code,'invalid_session');
 await q('insert into work_reports values($1,$2,$3,now(),$4,$5)',[id(91001),id(11),id(31),'clock_in',{worker:'테스트 직원',photo:'x'.repeat(100000)}]);
 const owner=await summary(o),staff=await summary(s1);assert.equal(owner.guest_unread,7);assert.equal(owner.report_unread,1);assert.equal(staff.report_unread,0);assert.equal(owner.staff_unread,owner.messenger_unread+1);
 assert(!('messages' in owner));assert(!('recipients' in owner));assert(!('reports' in owner));
 const first=await summary(o,null,true),again=await summary(o,first.revision,true);assert(first.messages_changed);assert(!again.messages_changed);assert(!('messages' in again));assert(!JSON.stringify(first).includes('data:image'));assert(!JSON.stringify(first).includes('x'.repeat(500)));
 await call(s1,'send',{peer:'owner:'+id(21),body:'new arrival',client_id:crypto.randomUUID()});
 const changed=await summary(o,first.revision,true);assert(changed.messages_changed);assert(changed.messages.some(m=>m.message==='new arrival'));
 const incoming=changed.messages.find(m=>m.message==='new arrival');await q('update property_message_recipients set read_at=now() where message_id=$1',[incoming.message_id]);
 assert((await summary(o,changed.revision,true)).messages_changed,'read transitions change revision even without a new message');
 await q("update property_messages set source='beds24' where id=$1",[incoming.message_id]);await q('update property_message_recipients set read_at=null where message_id=$1',[incoming.message_id]);const beforeTranslation=await summary(o,null,true);await db.exec("set test.popup='translated'");assert((await summary(o,beforeTranslation.revision,true)).messages_changed,'completed translation refreshes an open popup without a new message');
 const baseline=await rpc('list_property_messages',[o]);console.log('HOME EGRESS FIXTURE decoded bytes:',JSON.stringify({before:Buffer.byteLength(JSON.stringify(baseline)),badge:Buffer.byteLength(JSON.stringify(owner)),unchangedHome:Buffer.byteLength(JSON.stringify(again))}));
 console.log('PASS compact badges, owner/staff scope, invalid sessions, revision/read changes, no profiles/report payload, direct/group thumbnails, original authorization and legacy compatibility');
};
