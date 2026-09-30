import test from 'node:test';import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';
const id='00000000-0000-4000-8000-000000000001',other='00000000-0000-4000-8000-000000000002',original='00000000-0000-4000-8000-000000000003',fresh='00000000-0000-4000-8000-000000000004';
test('email session opens original room on new device without invalidating QR token; other rooms denied',async()=>{
 const db=new PGlite();try{
  await db.exec('create role anon;create role authenticated;create role service_role;create schema omg_private;create table properties(id uuid primary key,name text);');
  const s=await readFile(new URL('../../migrations/034_guest_support.sql',import.meta.url),'utf8');
  await db.exec(s.slice(0,s.indexOf('create or replace function omg_private.guest_actor'))+'commit;');
  await db.exec(s.slice(s.indexOf('create or replace function omg_private.guest_limit'),s.indexOf('-- All actions go through')));
  await db.exec("alter table guest_chat_rooms add column email text;alter table guest_chat_rooms add column room_unknown boolean default false;create function omg_private.token_hash(uuid) returns text language sql immutable strict as $$select encode(sha256(convert_to($1::text,'UTF8')),'hex')$$;create function omg_private.guest_actor(uuid) returns jsonb language sql as $$select null::jsonb$$;create function omg_private.guest_can_access(uuid,uuid) returns boolean language sql as $$select $1=$2$$;");
  const rpc=await readFile(new URL('../../migrations/039_guest_chat_alert_mode.sql',import.meta.url),'utf8');
  await db.exec(rpc.slice(rpc.indexOf('create or replace function public.guest_support_rpc'),rpc.indexOf('create or replace function public.get_guest_chat_dispatch')));
  await db.exec(await readFile(new URL('../../migrations/049_guest_email_relay.sql',import.meta.url),'utf8'));
  await db.exec(await readFile(new URL('../../migrations/050_guest_email_reply_link.sql',import.meta.url),'utf8'));
  await db.query('insert into properties values($1,$2),($3,$4)',[id,'One Minute',other,'Other']);
  await db.query('insert into guest_support_config(property_id,enabled,chat_enabled) values($1,true,true),($2,true,true)',[id,other]);
  await db.query("insert into guest_chat_rooms(id,property_id,guest_name,check_in,check_out,token_hash,expires_at,ip_hash,email) values($1,$1,'Guest',current_date,current_date+2,omg_private.token_hash($3),now()+interval '2 days','ip','guest@example.com'),($2,$2,'Other',current_date,current_date+2,'otherhash',now()+interval '2 days','ip','other@example.com')",[id,other,original]);
  await db.exec('update guest_email_config set enabled=true');
  await db.query("insert into guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body) values($1,gen_random_uuid(),'staff:test','Host','staff','원래 답변')",[id]);
  const token=(await db.query('select payload from guest_email_outbox')).rows[0].payload.link_token;
  assert.match(token,/^[a-f0-9]{64}$/);
  const opened=(await db.query('select open_guest_email($1,$2) r',[token,fresh])).rows[0].r;assert.equal(opened.room_id,id);
  const messages=async(room,guest)=>(await db.query("select guest_support_rpc('messages',$1::jsonb,null,$2,'') r",[JSON.stringify({room_id:room}),guest])).rows[0].r;
  assert.equal((await messages(id,fresh)).messages[0].body,'원래 답변');
  assert.equal((await messages(id,original)).messages[0].body,'원래 답변');
  await assert.rejects(messages(other,fresh),/권한/);
  await assert.rejects(db.query('select open_guest_email($1,gen_random_uuid())',['b'.repeat(64)]),/만료/);
  assert.equal((await db.query("select has_function_privilege('service_role','public.receive_guest_email(uuid,uuid,text,text,jsonb)','execute') v")).rows[0].v,false);
  assert.equal((await db.query("select has_function_privilege('anon','public.open_guest_email(text,uuid)','execute') v")).rows[0].v,false);
  await db.exec("update guest_email_links set expires_at=now()-interval '1 second'");
  await assert.rejects(db.query('select open_guest_email($1,gen_random_uuid())',[token]),/만료/);
  await db.exec("update guest_email_sessions set expires_at=now()-interval '1 second'");
  await assert.rejects(messages(id,fresh),/만료/);
  assert.equal((await messages(id,original)).messages.length,1);
 }finally{await db.close();}
});
