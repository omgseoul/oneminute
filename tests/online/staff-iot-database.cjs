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


 await db.exec(`alter table properties add service_plan text default 'basic';create table omg_private.service_plans(code text,employee_limit int);
 create table employees(id uuid,property_id uuid,active boolean default true,role text default 'staff');alter table omg_private.online_bookings add channel text;
 create table omg_private.iot_jobs(id uuid,property_id uuid,booking_id bigint,revision int,error text);
 create table omg_private.iot_notices(id uuid default gen_random_uuid(),job_id uuid,revision int,kind text,message_id uuid,unique(job_id,revision,kind));
 create or replace function omg_private.can_manage_shared_property(uuid,uuid,text) returns boolean language sql as $$select $1='${id(10)}'::uuid and $2='${id(1)}'::uuid$$;`);
 const iot=fs.readFileSync('supabase/setup/iot_doorlocks.sql','utf8');await db.exec(iot.slice(iot.indexOf('create function omg_private.iot_notice('),iot.indexOf('create function omg_private.iot_platform(')));
 await db.exec(fs.readFileSync('supabase/setup/staff_bot_and_iot_details.sql','utf8'));
 await db.query("insert into properties(id,name,management_number) values($1,'Nest',1),($2,'Other',2)",[id(1),id(2)]);
 await db.exec("insert into omg_private.service_plans values('basic',7)");await db.query('insert into employees(id,property_id) values($1,$2)',[id(11),id(1)]);
 let q=(await db.query('select public.staff_account_quota($1,$2) v',[id(10),id(1)])).rows[0].v;assert.deepEqual(q,{limit:7,count:1});
 await assert.rejects(()=>db.query('select public.staff_account_quota($1,$2)',[id(10),id(2)]),/권한/);
 await db.query("insert into omg_private.online_bookings(property_id,id,guest_name,room_name,channel,data)values($1,100,'Guest','401','Booking.com','{\"apiReference\":\"OTA100\"}')",[id(1)]);
 await db.query("insert into omg_private.iot_jobs values($1,$2,100,1,'failed')",[id(20),id(1)]);
 await db.query("select omg_private.iot_notice($1,'failed')",[id(20)]);
 const msg=(await db.query("select * from property_messages where source='iot_lock'")).rows[0];assert.match(msg.message,/예약사이트: Booking.com/);assert.match(msg.message,/사이트 예약번호: OTA100/);assert.match(msg.message,/Beds24 예약번호: 100/);
 const metadata=(await db.query('select omg_private.iot_notice_context($1,$2) v',[msg.id,id(1)])).rows[0].v;assert.equal(metadata.channel,'Booking.com');assert.equal((await db.query('select omg_private.iot_notice_context($1,$2) v',[msg.id,id(2)])).rows[0].v,null);
 console.log('Staff/IOT: actual plan limit/count, cross-property denial, channel/reference/booking IDs and metadata isolation passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
