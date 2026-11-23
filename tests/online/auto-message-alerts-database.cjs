const {PGlite}=require('@electric-sql/pglite'),fs=require('fs'),assert=require('node:assert/strict');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
(async()=>{const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema omg_private;create schema cron;
 create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
 create table properties(id uuid primary key,name text,management_number int,timezone text default 'Asia/Seoul',business_id uuid);
 create table owners(id uuid primary key,property_id uuid,active boolean default true);
 create table property_share_requests(requester_property_id uuid,target_property_id uuid,status text,requested_permissions text[]);
 create table notification_bots(property_id uuid,alert_mode text,display_name text);
 create table property_messages(id uuid primary key default gen_random_uuid(),business_id uuid,property_id uuid,sender_type text,message text,priority text,message_type text,source text,external_message_id text);
 create table property_message_recipients(message_id uuid,recipient_type text,owner_id uuid,recipient_key text);
 create table omg_private.online_connections(property_id uuid,vault_id uuid,beds_property_id bigint);
 create table omg_private.online_bookings(property_id uuid,id bigint,booked_at timestamptz,arrival date,departure date,status text,guest_name text,room_name text,data jsonb default '{}');
 create function omg_private.guest_actor(uuid) returns jsonb language sql as $$select jsonb_build_object('kind','owner','property_id','${id(1)}')$$;
 create function omg_private.can_manage_shared_property(uuid,uuid,text) returns boolean language sql as $$select false$$;
 create function public.get_briefing_push_dispatch(p_message_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare m public.property_messages%rowtype;begin
 select * into m from public.property_messages where id=p_message_id and source='bot_briefing';
 return jsonb_build_object('ok',found,'original',true);end$$;`);
 await db.exec(`create function public.list_property_messages(uuid) returns text language sql as $$select case when m.sender_type='system' then '근태관리' else '시스템' end from public.property_messages m limit 1$$;create function public.list_notification_bot_messages(uuid,timestamptz,uuid) returns text language sql as $$select case when m.sender_type='system' then '근태관리' else '시스템' end from public.property_messages m limit 1$$;`);
 await db.exec(fs.readFileSync('supabase/setup/guest_auto_messages.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/auto_message_exception_alerts.sql','utf8'));
 await db.query("insert into properties(id,name,management_number) values($1,'Nest',1),($2,'OMG',2),($3,'Other',3)",[id(1),id(2),id(3)]);
 await db.query('insert into owners(id,property_id) values($1,$2),($3,$4),($5,$6)',[id(10),id(1),id(20),id(2),id(30),id(3)]);
 await db.query("insert into property_share_requests values($1,$2,'approved','{messages,property_settings}'),($3,$2,'approved','{messages}')",[id(2),id(1),id(3)]);
 await db.query('insert into omg_private.online_connections values($1,$2,100)',[id(1),id(90)]);
 const owner=async(data)=>(await db.query("select public.auto_message_owner($1,'save',$2) v",[id(10),JSON.stringify({property_id:id(1),...data})])).rows[0].v;
 const ctl=async(action,data={})=>(await db.query('select public.auto_message_internal($1,$2) v',[action,JSON.stringify(data)])).rows[0].v;
 const scan=()=>db.query('select omg_private.auto_message_scan()');
 const count=async(kind)=>(await db.query('select count(*)::int n from omg_private.auto_message_notices where kind=$1',[kind])).rows[0].n;
 const draft={id:id(50),revision:0,title:'입실 안내',trigger:'booking_after',days:0,send_time:'09:30',messages:{common:'{{이름}} {{비밀번호}}'},enabled:true};
 await assert.rejects(()=>owner(draft),/1일부터/);
 await owner({...draft,trigger:'checkin_before',days:1});
 const due=(await db.query("select omg_private.auto_message_due('booking_after',1,'09:30','2026-12-31T14:00Z',null,'Asia/Seoul') v")).rows[0].v;
 assert.equal(new Date(due).toISOString(),'2027-01-01T00:30:00.000Z','local next calendar day, not 24 hours after booking');
 await db.exec("update omg_private.auto_message_rules set enabled_from=now()-interval '2 days'");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status,guest_name,room_name,data) values($1,100,now()-interval '1 hour',(now() at time zone 'Asia/Seoul')::date,(now() at time zone 'Asia/Seoul')::date+2,'confirmed','1234 Guest','201','{\"apiReference\":\"OTA100\"}')",[id(1)]);
 await scan();let j=(await db.query('select * from omg_private.auto_message_deliveries where booking_id=100')).rows[0];assert.equal(j.status,'skipped');assert.match(j.error,/예약 접수 전에/);assert.equal(await count('terminal'),1);assert.equal((await ctl('claim')).empty,true,'missed pre-checkin never sends late');await scan();assert.equal(await count('terminal'),1,'scan deduplicates');
 const notice=(await db.query('select * from property_messages')).rows[0];assert.match(notice.message,/Nest · 객실 201/);assert.match(notice.message,/예약 #100 · 채널 예약번호 OTA100/);assert(!notice.message.includes('1234'),'guest-facing numeric prefixes stripped');
 assert.equal((await db.query('select count(*)::int n from property_message_recipients')).rows[0].n,2,'home + authorized shared admins only');
 let push=(await db.query('select get_briefing_push_dispatch($1) v',[notice.id])).rows[0].v;assert.equal(push.recipient_topics.length,2);assert.match(push.sender_label,/자동메시지/);
 await db.query("update property_share_requests set status='revoked' where requester_property_id=$1",[id(2)]);push=(await db.query('select get_briefing_push_dispatch($1) v',[notice.id])).rows[0].v;assert.equal(push.recipient_topics.length,1,'recheck sharing at actual push');
 assert.equal((await ctl('pushes')).length,1);await ctl('pushed',{id:(await ctl('pushes'))[0].id});assert.equal((await ctl('pushes')).length,0);
 await db.query("insert into property_messages(id,source) values($1,'bot_briefing')",[id(70)]);assert.equal((await db.query('select get_briefing_push_dispatch($1) v',[id(70)])).rows[0].v.original,true,'existing briefing path unchanged');
 // A due reservation with missing PIN: one delay, retries, then one recovery.
 await db.exec("update omg_private.auto_message_rules set trigger='booking',days=0");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,101,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');assert.equal(j.booking_id,101);await ctl('finish',{...j,status:'waiting',error:'비밀번호 정보가 없어 발송을 대기합니다.'});assert.equal(await count('blocked'),1);
 await db.exec("update omg_private.auto_message_deliveries set next_at=now() where booking_id=101");j=await ctl('claim');await ctl('finish',{...j,status:'waiting',error:'비밀번호 정보가 없어 발송을 대기합니다.'});assert.equal(await count('blocked'),1);
 await db.exec("update omg_private.auto_message_deliveries set next_at=now() where booking_id=101");j=await ctl('claim');await ctl('prepare',j);await ctl('finish',{...j,status:'sent'});assert.equal(await count('recovered'),1);
 // Provider failed/uncertain sends are terminal, with no retry and one notice.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,102,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');await ctl('prepare',j);await ctl('finish',{...j,status:'uncertain',error:'전송 응답 끊김'});assert.equal(await count('terminal'),2);assert.equal((await ctl('claim')).empty,true);await ctl('finish',{...j,status:'uncertain',error:'전송 응답 끊김'});assert.equal(await count('terminal'),2);
 // Independent scan records an Edge worker that never claimed a pending job.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,103,now()-interval '10 minutes',current_date,current_date+2,'confirmed')",[id(1)]);await scan();await db.exec("update omg_private.auto_message_deliveries set created_at=now()-interval '10 minutes' where booking_id=103");await scan();assert.equal(await count('blocked'),2);
 j=await ctl('claim');await ctl('prepare',j);await db.exec("update omg_private.auto_message_deliveries set updated_at=now()-interval '4 minutes' where booking_id=103");await scan();assert.equal(await count('terminal'),3,'stuck sending becomes uncertain');
 // Intentional pause is not an error notification.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,104,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);await scan();await db.exec('update omg_private.auto_message_rules set enabled=false');await scan();assert.equal(await count('terminal'),3);
 // A cancellation discovered before sending is terminal; future check-in changes reschedule.
 await db.exec('update omg_private.auto_message_rules set enabled=true');
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,105,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');await db.exec("update omg_private.online_bookings set status='cancelled' where id=105");assert.equal((await ctl('prepare',j)).skip,true);assert.equal(await count('terminal'),4);
 await db.exec("update omg_private.auto_message_rules set trigger='checkin_before',days=1");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,106,now()-interval '2 days',current_date+1,current_date+3,'confirmed')",[id(1)]);
 await db.query("insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at) values($1,$2,106,'입실 안내',1,now()-interval '2 days')",[id(50),id(1)]);
 await db.exec("update omg_private.online_bookings set arrival=current_date+5,departure=current_date+7 where id=106");await scan();
 let future=(await db.query('select status,due_at>now() future from omg_private.auto_message_deliveries where booking_id=106')).rows[0];assert.equal(future.status,'waiting');assert.equal(future.future,true,'postponed check-in refreshes before expiration');
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.auto_message_scan()','execute') v")).rows[0].v,false);
 console.log('Auto alerts DB: min-day/time, missed deadline, deduped bot receipts, owner/shared access + revocation, delay/recovery, uncertain sends, watchdog and pause exclusion passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exit(1)});
