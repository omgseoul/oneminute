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
 await db.exec(fs.readFileSync('supabase/setup/auto_message_required_values.sql','utf8'));
 await db.exec(`drop function public.list_property_messages(uuid);drop function public.list_notification_bot_messages(uuid,timestamptz,uuid);
 create function public.list_property_messages(uuid) returns jsonb language plpgsql as $$declare v_is_owner boolean:=true;begin return (select jsonb_build_object('message_id',m.id,'property_id',m.property_id,'message',m.message) from public.property_messages m limit 1);end$$;
 create function public.list_notification_bot_messages(uuid,timestamptz,uuid) returns jsonb language plpgsql as $$declare v_is_owner boolean:=true;begin return (select jsonb_build_object('message_id',m.id,'property_id',m.property_id,'message',m.message) from public.property_messages m limit 1);end$$;`);
 await db.exec(fs.readFileSync('supabase/setup/auto_message_targeted_retry.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/auto_message_notice_stay.sql','utf8'));

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
 // Missing required values fail before prepare/send, retain all reasons and notify exactly once.
 await db.exec("update omg_private.auto_message_rules set trigger='booking',days=0");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,101,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');assert.equal(j.booking_id,101);
 await ctl('finish',{...j,lease:id(999),status:'failed',error:'wrong lease'});
 assert.equal((await db.query('select status from omg_private.auto_message_deliveries where id=$1',[j.id])).rows[0].status,'preparing');
 const missing='필수 정보가 없거나 확인되지 않았습니다: 이름, 비밀번호. 발송하지 않았습니다.';
 await ctl('finish',{...j,status:'failed',error:missing});
 const failed=(await db.query('select status,error,lease from omg_private.auto_message_deliveries where id=$1',[j.id])).rows[0];
 assert.equal(failed.status,'failed');assert.equal(failed.error,missing);assert.equal(failed.lease,null);
 assert.equal(await count('terminal'),2);assert.equal(await count('blocked'),0);
 const failedNotice=(await db.query("select m.message from property_messages m join omg_private.auto_message_notices n on n.message_id=m.id where n.delivery_id=$1",[j.id])).rows[0].message;
 assert.match(failedNotice,/자동메시지 발송실패/);assert.match(failedNotice,/이름, 비밀번호/);assert.match(failedNotice,/발송 기록에서 사유와 예약정보를 확인/);
 await ctl('finish',{...j,status:'failed',error:missing});await scan();
 assert.equal(await count('terminal'),2);assert.equal((await ctl('claim')).empty,true,'missing fields never automatically retry');
 // Provider failed/uncertain sends are terminal, with no retry and one notice.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,102,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');await ctl('prepare',j);await ctl('finish',{...j,status:'uncertain',error:'전송 응답 끊김'});assert.equal(await count('terminal'),3);assert.equal((await ctl('claim')).empty,true);await ctl('finish',{...j,status:'uncertain',error:'전송 응답 끊김'});assert.equal(await count('terminal'),3);
 // Independent scan records an Edge worker that never claimed a pending job.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,103,now()-interval '10 minutes',current_date,current_date+2,'confirmed')",[id(1)]);await scan();await db.exec("update omg_private.auto_message_deliveries set created_at=now()-interval '10 minutes' where booking_id=103");await scan();assert.equal(await count('blocked'),1);
 j=await ctl('claim');await ctl('prepare',j);await db.exec("update omg_private.auto_message_deliveries set updated_at=now()-interval '4 minutes' where booking_id=103");await scan();assert.equal(await count('terminal'),4,'stuck sending becomes uncertain');
 // Intentional pause is not an error notification.
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,104,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);await scan();await db.exec('update omg_private.auto_message_rules set enabled=false');await scan();assert.equal(await count('terminal'),4);
 // A cancellation discovered before sending is terminal; future check-in changes reschedule.
 await db.exec('update omg_private.auto_message_rules set enabled=true');
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,105,now()-interval '1 minute',current_date,current_date+2,'confirmed')",[id(1)]);
 j=await ctl('claim');await db.exec("update omg_private.online_bookings set status='cancelled' where id=105");assert.equal((await ctl('prepare',j)).skip,true);assert.equal(await count('terminal'),5);
 await db.exec("update omg_private.auto_message_rules set trigger='checkin_before',days=1");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status) values($1,106,now()-interval '2 days',current_date+1,current_date+3,'confirmed')",[id(1)]);
 await db.query("insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at) values($1,$2,106,'입실 안내',1,now()-interval '2 days')",[id(50),id(1)]);
 await db.exec("update omg_private.online_bookings set arrival=current_date+5,departure=current_date+7 where id=106");await scan();
 let future=(await db.query('select status,due_at>now() future from omg_private.auto_message_deliveries where booking_id=106')).rows[0];assert.equal(future.status,'waiting');assert.equal(future.future,true,'postponed check-in refreshes before expiration');
 // A worker that dies during lookup cannot leave a retryable delivery behind.
 await db.query("insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at,status,lease,leased_until) values($1,$2,107,'입실 안내',1,now(),'preparing',gen_random_uuid(),now()-interval '1 second')",[id(50),id(1)]);
 await scan();const expired=(await db.query('select status,error,lease from omg_private.auto_message_deliveries where booking_id=107')).rows[0];
 assert.equal(expired.status,'failed');assert.equal(expired.lease,null);assert.match(expired.error,/확인 시간이 초과/);assert.equal(await count('terminal'),6);
 await scan();assert.equal(await count('terminal'),6);assert.equal((await ctl('claim')).empty,true);
 // Three guests: one already sent, two failures. Only the two selected failures are retried.
 await db.exec("update omg_private.auto_message_rules set trigger='booking',days=0");
 await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status,guest_name,room_name) values($1,201,now()-interval '1 minute',current_date,current_date+2,'confirmed','Guest A','201'),($1,202,now()-interval '1 minute',current_date,current_date+2,'confirmed','Guest B','202'),($1,203,now()-interval '1 minute',current_date,current_date+2,'confirmed','Guest C','203')",[id(1)]);
 // Finish an earlier rescheduled fixture before the three-guest scenario.
 await db.exec("update omg_private.auto_message_deliveries set status='sent' where booking_id=106");
 const deliveries={};for(let n=0;n<3;n++){const x=await ctl('claim');deliveries[x.booking_id]=x;if(x.booking_id===201){await ctl('prepare',x);await ctl('finish',{...x,status:'sent'});}else await ctl('finish',{...x,status:'failed',error:'비밀번호 누락'});}
 const retry=async data=>(await db.query("select public.auto_message_owner($1,'retry',$2) v",[id(10),JSON.stringify({property_id:id(1),...data})])).rows[0].v;
 const targets=[202,203].map(n=>({id:deliveries[n].id,retry_count:0}));
 const oldNotice=(await db.query("select message_id from omg_private.auto_message_notices where delivery_id=$1 and kind='terminal'",[deliveries[203].id])).rows[0].message_id;
 assert.equal((await db.query('select omg_private.auto_message_notice_context($1,$2) v',[oldNotice,id(1)])).rows[0].v.can_retry,true);
 const stay=(await db.query('select arrival::text,departure::text from omg_private.online_bookings where property_id=$1 and id=203',[id(1)])).rows[0];
 await db.query("insert into omg_private.online_bookings(property_id,id,arrival,departure,status) values($1,203,'1999-01-01','1999-01-02','confirmed')",[id(2)]);
 const noticeContext=(await db.query('select omg_private.auto_message_notice_context($1,$2) v',[oldNotice,id(1)])).rows[0].v;
 assert.equal(noticeContext.arrival,stay.arrival);assert.equal(noticeContext.departure,stay.departure,'historical notice receives dates from its own property');
 await db.query('delete from omg_private.online_bookings where property_id=$1 and id=203',[id(2)]);
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.auto_message_notice_context(uuid,uuid)','execute') v")).rows[0].v,false);

 assert.equal((await db.query('select omg_private.auto_message_notice_context($1,$2) v',[oldNotice,id(2)])).rows[0].v,null,'notice metadata respects property');
 await assert.rejects(()=>retry({targets:[{id:id(999),retry_count:0}]}),/이 지점/);
 await db.exec("update omg_private.auto_message_deliveries set due_at=now()-interval '2 days' where booking_id in(202,203)");
 const selected=await retry({targets});assert.equal(selected.retry_queued,2);assert.equal(selected.logs.find(l=>l.booking_id===202).guest_name,'Guest B');assert.equal(selected.logs.find(l=>l.booking_id===201).status,'sent');
 assert.equal((await retry({targets})).retry_queued,0,'double tap cannot enqueue twice');
 assert.equal((await retry({notice_id:oldNotice})).retry_queued,0,'old notice cannot enqueue an active retry');
 const beforeRetryFailures=await count('terminal');
 for(let n=0;n<2;n++){const x=await ctl('claim');assert([202,203].includes(x.booking_id));assert.equal(x.manual_retry,true);assert.equal(x.retry_count,1);assert.equal((await ctl('prepare',x)).ok,true);await ctl('finish',{...x,status:x.booking_id===202?'sent':'failed',error:x.booking_id===203?'비밀번호 누락':null});}
 assert.equal((await ctl('claim')).empty,true);assert.equal(await count('terminal'),beforeRetryFailures+1,'only the guest who fails again generates a new failure notice');
 assert.equal((await retry({targets})).retry_queued,0,'stale batch cannot resend successful or newer-failed guests');
 const newNotice=(await db.query("select message_id from omg_private.auto_message_notices where delivery_id=$1 and retry_count=1 and kind='terminal'",[deliveries[203].id])).rows[0].message_id;
 const newBody=(await db.query('select message from property_messages where id=$1',[newNotice])).rows[0].message;assert.match(newBody,/Guest C/);assert(!newBody.includes('Guest B'));assert.match(newBody,/재전송: 1회/);
 assert.equal((await retry({notice_id:oldNotice})).retry_queued,0,'old failure cannot retry a newer failure');
 assert.equal((await retry({notice_id:newNotice})).retry_queued,1);const last=await ctl('claim');assert.equal(last.booking_id,203);assert.equal(last.retry_count,2);await ctl('finish',{...last,status:'failed',error:'비밀번호 누락'});
 assert.equal((await retry({targets:[{id:deliveries[201].id,retry_count:0}]})).retry_queued,0,'successful guest is never resent');
 await db.exec("update omg_private.auto_message_rules set enabled=false");assert.equal((await retry({targets:[{id:last.id,retry_count:2}]})).retry_queued,0,'paused rules require enabling');
 await db.exec(`create or replace function omg_private.guest_actor(uuid) returns jsonb language sql as $$select jsonb_build_object('kind','staff','property_id','${id(1)}')$$`);
 await assert.rejects(()=>retry({targets}),/관리자/);
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.auto_message_scan()','execute') v")).rows[0].v,false);

 // Latest migration: a newly received late booking sends once and alerts only after acceptance.
 await db.exec('alter table omg_private.online_bookings add column channel text');
 await db.exec(fs.readFileSync('supabase/setup/auto_message_late_booking_channel_alerts.sql','utf8'));
 await db.exec(`create or replace function omg_private.guest_actor(uuid) returns jsonb language sql as $$select jsonb_build_object('kind','owner','property_id','${id(1)}')$$`);
 await db.exec("truncate omg_private.auto_message_notices,omg_private.auto_message_deliveries,omg_private.auto_message_rules,omg_private.online_bookings cascade");
 await owner({...draft,trigger:'checkin_before',days:1});
 await db.exec("update omg_private.auto_message_rules set enabled_from=now()-interval '2 hours'");
 const addLate=async(n,booked="now()-interval '1 minute'",channel='Booking.com')=>db.query(`insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status,guest_name,room_name,channel,data) values($1,$2,${booked},(now() at time zone 'Asia/Seoul')::date,(now() at time zone 'Asia/Seoul')::date+2,'confirmed','1234 Late Guest','201',$3,'{"apiReference":"OTA-LATE"}')`,[id(1),n,channel]);
 await addLate(301);j=await ctl('claim');assert.equal(j.booking_id,301);assert.equal(j.status,'preparing');
 assert.equal(await count('terminal'),0,'late booking is not a failure');assert.equal(await count('exception'),0,'never claim success before provider acceptance');
 assert.equal((await ctl('prepare',j)).ok,true,'check-in day booking crosses old schedule but passes final gate');
 await ctl('finish',{...j,status:'sent'});assert.equal(await count('exception'),1);
 let exception=(await db.query("select m.message from property_messages m join omg_private.auto_message_notices n on n.message_id=m.id where n.delivery_id=$1 and n.kind='exception'",[j.id])).rows[0].message;
 assert.match(exception,/자동메시지 예외 발송 완료/);assert.match(exception,/예약사이트: Booking.com/);assert.match(exception,/Late Guest/);assert.match(exception,/설정된 발송 시점 이후/);assert.match(exception,/예약 #301/);assert.match(exception,/추가로 보내지 않아도/);
 let receipt=(await db.query('select late_booking,scheduled_at<due_at as original_earlier from omg_private.auto_message_deliveries where id=$1',[j.id])).rows[0];assert.deepEqual(receipt,{late_booking:true,original_earlier:true});
 await ctl('finish',{...j,status:'sent'});await scan();assert.equal(await count('exception'),1,'one success notice per attempt');assert.equal((await ctl('claim')).empty,true,'no duplicate guest send');
 let log=(await db.query("select public.auto_message_owner($1,'list',$2) v",[id(10),JSON.stringify({property_id:id(1)})])).rows[0].v.logs[0];assert.equal(log.late_booking,true);assert.equal(log.channel,'Booking.com');
 // Already existing bookings before activation stay excluded; nothing is resurrected.
 await addLate(302,"now()-interval '3 hours'");await scan();assert.equal((await db.query('select status from omg_private.auto_message_deliveries where booking_id=302')).rows[0].status,'skipped');assert.equal((await ctl('claim')).empty,true);
 // Unsupported channels produce a guest-specific terminal failure, including on manual retry.
 await addLate(303,"now()-interval '1 minute'",'Agoda');j=await ctl('claim');assert.equal(j.booking_id,303);await ctl('finish',{...j,status:'failed',error:'Beds24 메시지 연동을 지원하지 않는 예약사이트입니다.'});
 let failedRow=(await db.query("select n.message_id,m.message from omg_private.auto_message_notices n join property_messages m on m.id=n.message_id where n.delivery_id=$1 and n.kind='terminal'",[j.id])).rows[0];assert.match(failedRow.message,/예약사이트: Agoda/);assert.match(failedRow.message,/예약 #303/);assert.match(failedRow.message,/수동으로 확인/);assert(!failedRow.message.includes('예약 #301'));assert.equal(await count('exception'),1);
 assert.equal((await retry({notice_id:failedRow.message_id})).retry_queued,1);j=await ctl('claim');assert.equal(j.booking_id,303);await ctl('finish',{...j,status:'failed',error:'Beds24 메시지 연동을 지원하지 않는 예약사이트입니다.'});
 assert.equal((await db.query("select count(*)::int n from omg_private.auto_message_notices where delivery_id=$1 and kind='terminal'",[j.id])).rows[0].n,2);
 assert.equal((await retry({notice_id:failedRow.message_id})).retry_queued,0,'old notice never retries a new failure');
 // Changed booking dates, cancellation and pause still win over the exception.
 await addLate(304);j=await ctl('claim');await db.exec("update omg_private.online_bookings set arrival=arrival+5,departure=departure+5 where id=304");assert.equal((await ctl('prepare',j)).skip,true);assert.equal((await db.query('select status,due_at>now() future from omg_private.auto_message_deliveries where id=$1',[j.id])).rows[0].future,true);
 await addLate(305);j=await ctl('claim');await db.exec("update omg_private.online_bookings set status='cancelled' where id=305");assert.equal((await ctl('prepare',j)).skip,true);
 await addLate(306);j=await ctl('claim');await db.exec('update omg_private.auto_message_rules set enabled=false');assert.equal((await ctl('prepare',j)).skip,true);assert.equal(await count('exception'),1);
 // Local-date calculation handles multiple lead days, midnight and bookings before the scheduled time.
 const effective=async(trigger,days,booked,arrival,tz)=>(await db.query("select omg_private.auto_message_effective_due($1,$2,'09:00',$3,$4,$5) d",[trigger,days,booked,arrival,tz])).rows[0].d;
 assert.equal(new Date(await effective('checkin_before',2,'2026-11-25T23:30Z','2026-11-26','Asia/Seoul')).toISOString(),'2026-11-25T23:30:00.000Z');
 assert.equal(new Date(await effective('checkin_before',1,'2026-11-24T00:00Z','2026-11-27','Asia/Seoul')).toISOString(),'2026-11-26T00:00:00.000Z');
 assert.equal((await db.query("select has_function_privilege('anon','omg_private.auto_message_effective_due(text,integer,time,timestamptz,date,text)','execute') v")).rows[0].v,false);
 console.log('Late booking DB: receipt-time catch-up, final gate, original due audit, success-only deduped notice, OTA failure + scoped retry, activation boundary, date change, cancellation and pause passed');
 console.log('Auto alerts DB: min-day/time, missed deadline, deduped bot receipts, owner/shared access + revocation, strict missing-value failure, uncertain sends, failed lookup watchdog and pause exclusion passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exit(1)});
