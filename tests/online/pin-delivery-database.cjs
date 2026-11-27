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
 await db.query("insert into properties(id,name,management_number) values($1,'Nest',1),($2,'Other',2)",[id(1),id(2)]);
 await db.query("insert into omg_private.online_bookings(property_id,id,arrival,departure,booked_at,status,data) values($1,100,current_date+2,current_date+4,now(),'confirmed','{\"roomId\":20,\"unitId\":1}')",[id(1)]);
 const ctl=async(action,data={})=>(await db.query('select public.pin_delivery_internal($1,$2,$3) v',[action,id(1),JSON.stringify({booking_id:100,...data})])).rows[0].v;
 const state=async()=>(await ctl('state')).pin_delivery;
 assert.equal((await state()).state,'unknown');assert.equal((await state()).active,false);
 await ctl('observe',{pin:'0123'});assert.equal((await state()).configured,true);
 await ctl('begin',{id:id(11),pin:'0123',actor:'owner:test',title:'PIN'});assert.equal((await state()).state,'unknown');assert.equal((await state()).active,false);
 await ctl('finish',{id:id(11),status:'failed'});assert.equal((await state()).state,'failed');
 await ctl('begin',{id:id(12),pin:'0123'});await ctl('finish',{id:id(12),status:'sent'});
 assert.equal((await state()).state,'sent');assert(!JSON.stringify(await state()).includes('0123'),'PIN never disclosed in history');
 await ctl('observe',{pin:'1234'});assert.equal((await state()).state,'resend');
 await ctl('external',{id:id(13),pin:'1234',actor:'owner:test'});assert.equal((await state()).state,'sent');
 await ctl('external',{id:id(13),pin:'1234'});assert.equal((await state()).events.length,3,'external confirmation is idempotent');
 await db.query("update omg_private.online_bookings set departure=departure+1 where property_id=$1",[id(1)]);assert.equal((await state()).state,'resend','stay change invalidates delivered PIN');
 await ctl('observe',{pin:null});assert.equal((await state()).configured,false);assert.equal((await state()).state,'resend');
 await assert.rejects(()=>db.query("select public.pin_delivery_internal('state',$1,'{\"booking_id\":100}')",[id(2)]),/예약/);
 await db.exec('set role anon');await assert.rejects(()=>ctl('state'),/permission/);await assert.rejects(()=>db.query('select * from omg_private.pin_delivery_events'),/permission/);await db.exec('reset role');
 // Rule scheduling is computed without reading any guest conversation.
 await db.query("insert into omg_private.online_bookings(property_id,id,arrival,departure,booked_at,status) values($1,101,current_date+60,current_date+61,now(),'confirmed')",[id(1)]);
 await db.query("insert into omg_private.auto_message_rules(id,property_id,title,trigger,days,send_time,messages,enabled,pin_notice) values($1,$2,'PIN','checkin_before',2,'09:00','{\"common\":\"{{비밀번호}}\"}',true,true)",[id(20),id(1)]);
 const future=async()=>(await db.query('select omg_private.pin_delivery_state($1,101) v',[id(1)])).rows[0].v;
 assert.equal((await future()).active,true);assert.equal((await future()).state,'scheduled');assert((await future()).due_at);
 await db.query("update omg_private.online_bookings set arrival=current_date,departure=current_date+1 where id=101");assert.equal((await future()).state,'unsent');
 await db.exec('update omg_private.auto_message_rules set enabled=false');assert.equal((await future()).active,false,'unused/disabled auto PIN rules hide delivery status');
 console.log('PIN ledger: exact PIN version, leading zero, current stay, external deduplication, future due and access isolation passed');
 }finally{await db.close();}})().catch(e=>{console.error(e);process.exitCode=1});
