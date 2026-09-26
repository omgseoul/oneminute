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

 await db.exec(read('migrations/034_guest_support.sql'));
 await db.exec(read('setup/002_register_employee_pins.example.sql').replace(/PIN_([1-4])/g,'731482'));
 await db.exec(read('setup/007_create_owner.example.sql').replace(/OWNER_LOGIN_ID/g,'boss.test').replace(/OWNER_PIN_6_TO_8/g,'517394'));
 const owner=await rpc('start_owner_session',['boss.test','517394']);
 const staff=(await db.query("select id,property_id from public.employees where active and role<>'owner' order by id")).rows;
 const worker=await rpc('start_work_session',[staff[0].id,'731482']);

 const crypto=require('node:crypto');
 const first=staff.find(s=>s.property_id===owner.property_id)||staff[0];
 const second=staff.find(s=>s.property_id===first.property_id&&s.id!==first.id);
 const token=(await rpc('start_work_session',[first.id,'731482'])).access_token;
 const token2=(await rpc('start_work_session',[second.id,'731482'])).access_token;
 const api=(t,a,d={})=>rpc('staff_chat_rpc',[t,a,JSON.stringify(d)]);
 const peer='employee:'+first.id,peer2='employee:'+second.id;
 const info=await rpc('list_property_messages',[token]);const boss=info.recipients.find(x=>x.recipient_type==='owner');
 check(!!boss,'staff can choose owner by stable account ID');
 const ownerToken=owner.access_token;
 const request={peer,body:'첫 대화',priority:'urgent',client_id:crypto.randomUUID()};
 const sent=await api(ownerToken,'send',request);check(sent.ok,'owner sends through existing message storage');
 const repeat=await api(ownerToken,'send',request);check(repeat.message_id===sent.message_id&&repeat.duplicate,'retry does not duplicate message');
 await assert.rejects(()=>api(ownerToken,'send',{...request,body:'changed'}));check(true,'idempotency ID cannot overwrite body');
 let rooms=await api(token,'rooms');check(rooms.rooms.length===1&&rooms.rooms[0].unread===1,'recipient sees unread conversation');
 const bossKey=rooms.rooms[0].peer;
 let page=await api(token,'messages',{peer:bossKey});check(page.messages[0].priority==='urgent'&&!page.messages[0].mine,'urgent remains urgent in incoming bubble');
 await api(token,'read',{peer:bossKey,ids:[sent.message_id]});check((await api(token,'rooms')).rooms[0].unread===0,'reading conversation clears unread');
 check((await api(token2,'rooms')).rooms.length===0,'unrelated employee cannot see conversation');
 const page2=await api(token2,'messages',{peer:bossKey});check(page2.messages.length===0,'selecting same owner does not leak another employee messages');
 const reply=await api(token,'send',{peer:bossKey,body:'답장',priority:'normal',client_id:crypto.randomUUID()});check(reply.ok,'inline reply uses correct owner account');
 page=await api(ownerToken,'messages',{peer});check(page.messages.length===2&&page.messages[0].mine&&!page.messages[1].mine,'both directions share a conversation');
 const broadcast=await rpc('send_shared_property_message',[ownerToken,[first.id,second.id],[],'전체 전달','normal','general']);
 check(broadcast.ok,'legacy multi-recipient send remains supported');
 page=await api(token2,'messages',{peer:bossKey});check(page.messages.length===1&&page.messages[0].broadcast,'broadcast appears without private replies');
 const notice=await rpc('send_shared_property_message',[ownerToken,[first.id],[],'확인 필요','normal','announcement']);
 check(!(await api(token,'messages',{peer:bossKey})).messages.some(x=>x.id===notice.message_id),'announcements stay out of chat');
 await api(token,'read',{peer:bossKey,ids:[notice.message_id]});
 check(!(await one('select read_at from property_message_recipients where message_id=$1',[notice.message_id])).read_at,'chat read cannot bypass notice acknowledgement');
 for(let i=0;i<55;i++)await api(ownerToken,'send',{peer,body:'page '+i,client_id:crypto.randomUUID()});
 page=await api(token,'messages',{peer:bossKey});check(page.messages.length===50,'history loads in bounded pages');
 const firstPage=page.messages[0];const older=await api(token,'messages',{peer:bossKey,before_time:firstPage.created_at,before_id:firstPage.id});
 check(older.messages.length===8&&!older.messages.some(x=>page.messages.some(y=>x.id===y.id)),'older history is complete with no duplicates');
 const newest=page.messages.at(-1);await api(ownerToken,'send',{peer,body:'new',client_id:crypto.randomUUID()});
 const fresh=await api(token,'messages',{peer:bossKey,after_time:newest.created_at,after_id:newest.id});check(fresh.messages.length===1&&fresh.messages[0].body==='new','incremental polling fetches only newer messages');
 await assert.rejects(()=>api(crypto.randomUUID(),'rooms'));check(true,'invalid sessions rejected');
 check((await api(ownerToken,'resolve',{message_id:reply.message_id})).peer===peer,'notification deep link resolves same conversation');
 const dispatch=await rpc('get_message_push_dispatch',[ownerToken,sent.message_id]);check(dispatch.ok&&dispatch.priority==='urgent'&&dispatch.recipient_employee_ids.includes(first.id),'existing urgent push dispatch preserved');
 await db.close();console.log(count+' staff conversation checks passed');
})().catch(e=>{console.error(e);process.exitCode=1;db.close();});
