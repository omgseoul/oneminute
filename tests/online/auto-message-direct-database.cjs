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


 await db.exec('alter table omg_private.online_bookings add column channel text;alter table owners add column display_name text;create table employees(id uuid,display_name text);');
 await db.exec(fs.readFileSync('supabase/setup/auto_message_late_booking_channel_alerts.sql','utf8'));
 await db.exec(`create function omg_private.online_owner(uuid,text,jsonb) returns jsonb language sql as $$select to_jsonb(x) from(select b.* from omg_private.online_bookings b)x$$;
 create function omg_private.online_booking_data(uuid,text,jsonb,text) returns jsonb language sql as $$select to_jsonb(x) from(select b.status,b.channel,b.data,b.id from omg_private.online_bookings b)x$$;
 create function omg_private.iot_internal(p_action text,p_property uuid,p_data jsonb) returns jsonb language plpgsql as $$declare j record;begin
   if p_data->>'status' in('done','failed','revoked') then perform omg_private.iot_notice(j.id,p_data->>'status');end if;
 return '{}'::jsonb;end$$;`);
 await db.exec(fs.readFileSync('supabase/setup/pin_delivery_tracking.sql','utf8'));
 await db.exec(`alter table employees add column property_id uuid,add column active boolean default true;alter table property_message_recipients add column employee_id uuid;
 create table work_sessions(employee_id uuid,property_id uuid,status text,checkin_report_at timestamptz,checkout_report_at timestamptz,token_expires_at timestamptz);
 create or replace function omg_private.guest_actor(p_token uuid) returns jsonb language sql as $$select case when p_token='${id(10)}' then jsonb_build_object('kind','owner','property_id','${id(1)}','id','${id(10)}','key','owner:${id(10)}') when p_token='${id(20)}' then jsonb_build_object('kind','staff','property_id','${id(1)}','id','${id(20)}','key','employee:${id(20)}') when p_token='${id(30)}' then jsonb_build_object('kind','owner','property_id','${id(2)}','id','${id(30)}') else null end$$;`);
 await db.exec(fs.readFileSync('supabase/setup/auto_message_followups.sql','utf8'));
 await db.exec(`insert into properties(id,name,management_number) values('${id(1)}','Nest',1),('${id(2)}','Other',2);
 insert into owners(id,property_id) values('${id(10)}','${id(1)}'),('${id(30)}','${id(2)}');
 insert into employees(id,property_id,display_name) values('${id(20)}','${id(1)}','Staff');
 insert into work_sessions values('${id(20)}','${id(1)}','working',now(),null,now()+interval '1 day');
 insert into omg_private.online_connections(property_id,vault_id,beds_property_id) values('${id(1)}','${id(90)}',100);`);
 const call=async(sql,args=[])=>(await db.query(sql,args)).rows[0]?.v;
 const owner=data=>call("select public.auto_message_owner($1,'save',$2) v",[id(10),JSON.stringify({property_id:id(1),...data})]);
 const ctl=(action,data={})=>call('select public.auto_message_internal($1,$2) v',[action,JSON.stringify(data)]);
 const action=(token,d,act,extra={})=>call('select public.auto_message_followup($1,$2) v',[token,JSON.stringify({delivery_id:d.id,retry_count:d.retry_count,action:act,...extra})]);
 const calendar=(act,data={})=>call('select public.pin_calendar_internal($1,$2) v',[act,JSON.stringify(data)]);
 const count=table=>call(`select count(*)::int v from omg_private.${table}`);
 const rule={id:id(50),revision:0,title:'PIN',trigger:'booking',days:0,send_time:'09:00',messages:{common:'PIN {{비밀번호}}'},pin_notice:true,calendar_pin_sent:true,enabled:true};
 await owner(rule);
 await db.exec("update omg_private.auto_message_rules set enabled_from=now()-interval '2 days'");
 const book=async bid=>{await db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status,guest_name,room_name,data) values($1,$2,now()-interval '1 minute',current_date+1,current_date+2,'confirmed','Guest','101','{\"roomId\":20,\"unitId\":1}')",[id(1),bid]);return ctl('claim');};
 const fail=async bid=>{const j=await book(bid);assert.equal(j.booking_id,bid);await ctl('finish',{...j,status:'failed',error:'Unsupported channel'});return j;};
 const failed=await fail(100);
 await db.exec("update omg_private.auto_message_followups set next_notice_at=now()-interval '1 second';select omg_private.auto_message_followup_scan()");
 const preparing=await book(102);
 const sent=await book(103);await ctl('prepare',{...sent,language:'common',pin:'0234'});await ctl('finish',{...sent,status:'sent'});
 const uncertain=await book(104);await ctl('prepare',{...uncertain,language:'common',pin:'0345'});await ctl('finish',{...uncertain,status:'uncertain'});
 await db.exec(`alter table property_message_recipients add column read_at timestamptz;`);
 const sameDay=fs.readFileSync('supabase/setup/beds24_booking_data.sql','utf8');
 await db.exec(sameDay.slice(0,sameDay.indexOf('create or replace function omg_private.online_booking_data')));
 await db.exec(sameDay.slice(sameDay.indexOf('create or replace function omg_private.online_same_day_notice'),sameDay.indexOf('create or replace function omg_private.online_booking_pending')));
 const insert=async(bid,data={},channel=null,status='confirmed')=>db.query("insert into omg_private.online_bookings(property_id,id,booked_at,arrival,departure,status,guest_name,room_name,data,channel) values($1,$2,now()-interval '1 minute',(now() at time zone 'Asia/Seoul')::date,(now() at time zone 'Asia/Seoul')::date+2,$3,'Guest','101',$4,$5)",[id(1),bid,status,JSON.stringify(data),channel]);
 await insert(101,{apiSource:'Booking.com'},'Booking.com');
 const sameMid=await call('select message_id v from omg_private.online_booking_notices where booking_id=101');
 assert.ok(sameMid);assert.equal((await call('select public.get_online_push_dispatch($1) v',[sameMid])).recipient_topics.length,2);
 await db.exec("update omg_private.online_bookings set channel='Direct',data=data||'{\"apiSource\":\"Direct\"}' where id in(100,101,102,103,104)");
 await db.exec("insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at,status) select id,property_id,101,title,revision,now(),'waiting' from omg_private.auto_message_rules");
 const beforeMessages=await call('select count(*)::int v from property_messages');
 await db.exec(fs.readFileSync('supabase/setup/auto_message_direct_exclusion.sql','utf8'));
 for(const [data,channel,expected] of [[{},null,false],[{apiSourceId:null},null,false],[{apiSourceId:''},null,false],
  [{apiSourceId:0},'Custom',true],[{apiSourceId:'0',apiSource:'Other'},null,true],[{apiSource:'Direct'},null,true],[{},' manual_booking ',true],
  [{referer:'다이렉트 예약'},null,true],[{apiSourceId:19},'Direct',false],[{apiSource:'Booking.com',referer:'Direct'},null,false],[{apiSourceId:1,apiSource:'Booking Page'},null,false]]){
  assert.equal(await call('select omg_private.online_is_direct($1,$2) v',[JSON.stringify(data),channel]),expected,JSON.stringify(data));
 }
 assert.deepEqual((await db.query('select booking_id,status from omg_private.auto_message_deliveries order by booking_id')).rows,[
  {booking_id:100,status:'skipped'},{booking_id:101,status:'skipped'},{booking_id:102,status:'skipped'},{booking_id:103,status:'sent'},{booking_id:104,status:'uncertain'}]);
 assert.equal(await call("select count(*)::int v from omg_private.auto_message_followups where status in('open','planned')"),0);
 assert.equal(await call('select count(*)::int v from property_message_recipients where read_at is null'),0,'queued Direct popups cleared without deleting history');
 assert.equal(await call('select count(*)::int v from property_messages'),beforeMessages);
 assert.equal((await call('select public.get_online_push_dispatch($1) v',[sameMid])).recipient_topics.length,0);
 const noticeId=await call('select message_id v from omg_private.auto_message_notices where delivery_id=$1 limit 1',[failed.id]);
 assert.equal((await call('select omg_private.auto_message_push_dispatch($1) v',[noticeId])).recipient_topics.length,0);
 const reminderId=await call('select message_id v from omg_private.auto_message_reminders where delivery_id=$1 limit 1',[failed.id]);
 assert.equal((await call('select omg_private.auto_message_push_dispatch($1) v',[reminderId])).recipient_topics.length,0);
 await db.exec("update omg_private.auto_message_followups set next_notice_at=now()-interval '1 hour';select omg_private.auto_message_followup_scan()");
 assert.equal(await count('auto_message_reminders'),1,'Direct hourly reminders stop');
 const retried=await call("select public.auto_message_owner($1,'retry',$2) v",[id(10),JSON.stringify({property_id:id(1),targets:[{id:failed.id,retry_count:0}]})]);
 assert.equal(retried.retry_queued,0);assert.match(retried.retry_results[0].message,/다이렉트/);
 for(const [bid,data,channel] of [[200,{apiSource:'Direct'},'Direct'],[201,{apiSourceId:0},'custom'],[202,{},'Manual']])await insert(bid,data,channel);
 assert.equal(await count('online_booking_notices'),1,'Direct creates no new same-day notice');
 assert.equal((await ctl('claim')).empty,true,'Direct creates no auto-message delivery');
 const state=await call('select omg_private.pin_delivery_state($1,200) v',[id(1)]);assert.equal(state.active,false);assert.equal(state.state,'excluded');assert.equal(state.due_at,null);
 await insert(203,{apiSourceId:19,apiSource:'Booking.com'},'Direct','request');
 assert.equal(await count('online_booking_notices'),2,'authoritative OTA ID overrides misleading Direct label');
 await insert(204,{apiSourceId:1,apiSource:'Booking Page'},'Booking Page','request');
 assert.equal(await count('online_booking_notices'),2,'existing Booking Page same-day policy preserved');
 await insert(205,{apiSourceId:19,apiSource:'Booking.com'},'Booking.com');
 const claimed=await ctl('claim');assert.equal(claimed.booking_id,205);
 const newMid=await call('select message_id v from omg_private.online_booking_notices where booking_id=205');
 await db.exec("update omg_private.online_bookings set data='{\"apiSourceId\":0}',channel='Custom' where id=205");
 // Gates act immediately, even before the next cleanup sweep.
 assert.equal((await call('select public.get_online_push_dispatch($1) v',[newMid])).recipient_topics.length,0);
 const gated=await ctl('prepare',{...claimed,language:'common',pin:'0456'});assert.equal(gated.excluded,true);
 assert.equal(await call('select count(*)::int v from omg_private.pin_delivery_events where booking_id=205'),0);
 assert.equal(await call('select status v from omg_private.auto_message_deliveries where id=$1',[claimed.id]),'skipped');
 await ctl('finish',{...claimed,status:'failed',error:'stale worker'});
 assert.equal(await call('select status v from omg_private.auto_message_deliveries where id=$1',[claimed.id]),'skipped','stale worker cannot undo exclusion');
 await insert(206,{apiSourceId:19,apiSource:'Booking.com'},'Booking.com');
 const ota=await ctl('claim');assert.equal(ota.booking_id,206);assert.equal((await ctl('prepare',{...ota,language:'common',pin:'0567'})).ok,true);
 await ctl('finish',{...ota,status:'sent'});assert.equal(await call('select status v from omg_private.auto_message_deliveries where id=$1',[ota.id]),'sent');
 const live=await book(207);await db.exec("update omg_private.online_bookings set data='{\"apiSourceId\":0}' where id=207");
 assert.equal((await ctl('exclude_direct',live)).excluded,true);
 // An earlier unsupported-channel failure cannot recreate a Direct notification.
 const countBefore=await call('select count(*)::int v from property_messages');
 await db.query("select omg_private.auto_message_notice($1,'terminal')",[live.id]);assert.equal(await call('select count(*)::int v from property_messages'),countBefore);
 await db.exec('set role anon');await assert.rejects(()=>call("select omg_private.online_is_direct('{}') v"),/permission/);await assert.rejects(()=>db.exec('select omg_private.auto_message_exclude_direct()'),/permission/);await db.exec('reset role');
 console.log('Direct database: same-day/auto scheduling exclusions, source precedence, existing queues and hourly reminder cleanup, late source changes, retries, PIN status, preserved sent evidence and OTA sends passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exit(1)});
