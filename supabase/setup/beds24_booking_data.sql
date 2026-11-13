-- Booking occurrence list and deduplicated same-day booking notifications.
alter table omg_private.online_connections add column if not exists same_day_alert jsonb not null default '{"enabled":true,"notify_staff":true,"staff_mode":"normal","notify_owner":true,"owner_mode":"normal"}';
create table if not exists omg_private.online_booking_notices(property_id uuid not null references public.properties(id) on delete cascade,booking_id bigint not null,message_id uuid unique references public.property_messages(id) on delete cascade,created_at timestamptz not null default now(),primary key(property_id,booking_id));
alter table omg_private.online_booking_notices enable row level security;
revoke all on omg_private.online_booking_notices from public,anon,authenticated;
create index if not exists online_booking_notice_recent on omg_private.online_booking_notices(created_at);

create or replace function omg_private.online_booking_data(prop uuid,action text,p_data jsonb,tz text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare first_day date;last_day date;local_day date:=(now() at time zone coalesce(nullif(tz,''),'Asia/Seoul'))::date;cfg jsonb;result jsonb;begin
 if action='save_booking_alert' then
  cfg:=p_data->'config';
  if jsonb_typeof(cfg)<>'object' or coalesce(cfg->>'staff_mode','') not in('weak','normal','strong','urgent') or coalesce(cfg->>'owner_mode','') not in('weak','normal','strong','urgent') then raise exception '당일 예약 알림 설정을 확인해주세요.';end if;
  cfg:=jsonb_build_object('enabled',coalesce((cfg->>'enabled')::boolean,false),'notify_staff',coalesce((cfg->>'notify_staff')::boolean,false),'staff_mode',cfg->>'staff_mode','notify_owner',coalesce((cfg->>'notify_owner')::boolean,false),'owner_mode',cfg->>'owner_mode');
  update omg_private.online_connections set same_day_alert=cfg where property_id=prop;return jsonb_build_object('ok',true,'same_day_alert',cfg);
 elsif action='booking_data_count' then
  return jsonb_build_object('ok',true,'count',(select count(*) from omg_private.online_bookings b where b.property_id=prop and b.arrival=local_day and b.booked_at >= (local_day::timestamp at time zone coalesce(tz,'Asia/Seoul')) and b.booked_at < ((local_day+1)::timestamp at time zone coalesce(tz,'Asia/Seoul')) and b.status in('new','confirmed','request')));
 end if;
 first_day:=(p_data->>'from')::date;last_day:=(p_data->>'to')::date;
 if first_day is null or last_day is null or last_day<first_day or last_day-first_day>92 then raise exception '예약 발생일 조회는 최대 93일입니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.booked_at desc,x.id desc),'[]') into result from(
  select b.id,b.guest_name,b.room_name,b.arrival,b.departure,b.booked_at,b.status,b.channel,b.data,
   b.arrival=(b.booked_at at time zone coalesce(tz,'Asia/Seoul'))::date same_day,
   b.arrival=(b.booked_at at time zone coalesce(tz,'Asia/Seoul'))::date+1 next_day
  from omg_private.online_bookings b where b.property_id=prop and b.booked_at >= (first_day::timestamp at time zone coalesce(tz,'Asia/Seoul')) and b.booked_at < ((last_day+1)::timestamp at time zone coalesce(tz,'Asia/Seoul'))
  order by b.booked_at desc,b.id desc limit 300 offset greatest(0,least(15000,coalesce((p_data->>'offset')::int,0)))
 )x;
 return jsonb_build_object('ok',true,'bookings',result,'synced_at',(select synced_at from omg_private.online_connections where property_id=prop));
end$$;
revoke all on function omg_private.online_booking_data(uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function omg_private.online_booking_data(uuid,text,jsonb,text) to service_role;

create or replace function omg_private.online_same_day_notice() returns trigger language plpgsql security definer set search_path='' as $$
declare tz text;cfg jsonb;local_day date;notice uuid;reserved uuid;begin
 select p.timezone,c.same_day_alert into tz,cfg from public.properties p join omg_private.online_connections c on c.property_id=p.id where p.id=new.property_id;
 local_day:=(now() at time zone coalesce(tz,'Asia/Seoul'))::date;
 if not coalesce((cfg->>'enabled')::boolean,false) or not coalesce(new.status in('new','confirmed','request'),false) or new.booked_at is null or new.arrival is distinct from local_day or (new.booked_at at time zone coalesce(tz,'Asia/Seoul'))::date<>local_day then return new;end if;
 if tg_op='UPDATE' then
  if old.arrival is not distinct from new.arrival and old.booked_at is not distinct from new.booked_at and old.status in('new','confirmed','request') then return new;end if;
 end if;
 insert into omg_private.online_booking_notices(property_id,booking_id)values(new.property_id,new.id)on conflict do nothing returning property_id into reserved;
 if reserved is null then return new;end if;
 insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
 select p.business_id,p.id,'system','[OMS-BOOKING:'||new.id||']'||E'\n당일 예약 접수\n'||new.guest_name||' · '||coalesce(new.room_name,'객실 미정')||E'\n'||new.arrival||' → '||new.departure||' · '||coalesce(new.channel,'출처 미확인'),'normal','general','beds24_booking',new.property_id||':'||new.id from public.properties p where p.id=new.property_id returning id into notice;
 update omg_private.online_booking_notices set message_id=notice where property_id=new.property_id and booking_id=new.id;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)
 select notice,'owner:'||o.id,'owner',o.id,null from public.owners o where o.property_id=new.property_id and o.active and coalesce((cfg->>'notify_owner')::boolean,false)
 union select notice,'employee:'||e.id,'staff',null,e.id from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=new.property_id and e.property_id=new.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now() and coalesce((cfg->>'notify_staff')::boolean,false);
 return new;
end$$;
revoke all on function omg_private.online_same_day_notice() from public,anon,authenticated;
drop trigger if exists online_same_day_booking on omg_private.online_bookings;
create trigger online_same_day_booking after insert or update on omg_private.online_bookings for each row execute function omg_private.online_same_day_notice();

create or replace function public.get_online_push_dispatch(p_message_id uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare m record;topics jsonb;modes jsonb;cfg jsonb;bid bigint;begin
 select msg.*,p.management_number into m from public.property_messages msg join public.properties p on p.id=msg.property_id where msg.id=p_message_id and msg.source in('beds24','beds24_booking');
 if not found then return jsonb_build_object('ok',false);end if;
 if m.source='beds24_booking' then
  select same_day_alert into cfg from omg_private.online_connections where property_id=m.property_id;
  select booking_id into bid from omg_private.online_booking_notices where message_id=m.id and property_id=m.property_id;
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
   select 'property_'||m.management_number||'_owner_'||r.owner_id topic,cfg->>'owner_mode' mode from public.property_message_recipients r join public.owners o on o.id=r.owner_id where r.message_id=m.id and r.recipient_type='owner' and o.active and o.property_id=m.property_id and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_owner')::boolean,false)
   union select 'property_'||m.management_number||'_employee_'||r.employee_id,cfg->>'staff_mode' from public.property_message_recipients r join public.employees e on e.id=r.employee_id where r.message_id=m.id and r.recipient_type='staff' and e.active and e.property_id=m.property_id and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_staff')::boolean,false) and exists(select 1 from public.work_sessions w where w.employee_id=e.id and w.property_id=m.property_id and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now())
  )x;
  return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-BOOKING:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'sender_label','당일 예약','priority','normal','route','messages.html#bot');
 end if;
 select coalesce(jsonb_agg('property_'||m.management_number||'_owner_'||r.owner_id),'[]'),coalesce(jsonb_object_agg('property_'||m.management_number||'_owner_'||r.owner_id,'normal'),'{}') into topics,modes from public.property_message_recipients r where r.message_id=m.id and r.recipient_type='owner';
 return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-ONLINE:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'route','online.html#thread/'||(select booking_id from omg_private.online_messages where notice_id=m.id limit 1)||'?property='||m.property_id);
end$$;
revoke all on function public.get_online_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_online_push_dispatch(uuid) to service_role;

create or replace function omg_private.online_booking_pending(prop uuid)returns jsonb language sql security invoker set search_path='' as $$
 select coalesce(jsonb_agg(x.id),'[]') from(
  select notice_id id from omg_private.online_messages where property_id=prop and notice_id is not null and created_at>now()-interval '5 minutes'
  union select message_id from omg_private.online_booking_notices where property_id=prop and message_id is not null and created_at>now()-interval '5 minutes'
 )x
$$;
revoke all on function omg_private.online_booking_pending(uuid) from public,anon,authenticated;

do $patch$
declare definition text;needle text;start_at int;end_at int;begin
 definition:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(definition,'''same_day_alert'',c.same_day_alert')=0 then
  needle:='''translation_connected'',c.translation_vault_id is not null';
  if strpos(definition,needle)=0 then raise exception '온라인 설정 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,'''same_day_alert'',c.same_day_alert,'||needle);
 end if;
 if strpos(definition,'p_action in(''booking_data'',''booking_data_count'',''save_booking_alert'')')=0 then
  needle:=' elsif p_action=''save_settings'' then';
  if strpos(definition,needle)=0 then raise exception '예약 Data 함수 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,E' elsif p_action in(''booking_data'',''booking_data_count'',''save_booking_alert'') then\n  return omg_private.online_booking_data(home,p_action,p_data,tz);\n'||needle);
 end if;
 execute definition;
 definition:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);
 if strpos(definition,'online_booking_pending(p_property)')=0 then
  needle:='return coalesce((select jsonb_agg(notice_id) from omg_private.online_messages where property_id=p_property and notice_id is not null and created_at>now()-interval ''5 minutes''),''[]'');';
  if strpos(definition,needle)=0 then raise exception '예약 알림 대기열 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,'return omg_private.online_booking_pending(p_property);');
  needle:='if p_action=''maintenance'' then';
  definition:=replace(definition,needle,E'if p_action=''booking_push_properties'' then\n  return coalesce((select jsonb_agg(distinct property_id) from omg_private.online_booking_notices where message_id is not null and created_at>now()-interval ''5 minutes''),''[]'');\n elsif p_action=''maintenance'' then');
 end if;
 execute definition;
end $patch$;
