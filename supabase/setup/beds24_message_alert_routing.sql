-- Activate saved online-message preferences without changing receipt screen layout.
alter table omg_private.online_connections add column if not exists online_message_alert jsonb;
update omg_private.online_connections set online_message_alert=online_message_alert_draft where online_message_alert is null and online_message_alert_draft is not null;

create or replace function omg_private.online_message_scope_matches(scopes jsonb,arrival date,departure date,day date)returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(scopes ? 'all' or (scopes ? 'checkin' and arrival=day) or (scopes ? 'staying' and arrival<day and departure>day) or (scopes ? 'checkout' and departure=day),false)
$$;
revoke all on function omg_private.online_message_scope_matches(jsonb,date,date,date) from public,anon,authenticated;
grant execute on function omg_private.online_message_scope_matches(jsonb,date,date,date) to service_role;

create or replace function omg_private.online_message_alert_recipients(prop uuid,bid bigint,at_time timestamptz default now())returns table(recipient_key text,recipient_type text,owner_id uuid,employee_id uuid,mode text)language plpgsql stable security invoker set search_path='' as $$
declare cfg jsonb;tz text;day date;local_time time;arrival date;departure date;has_staff boolean;owner_allowed boolean;window_from time;window_to time;begin
 select c.online_message_alert,p.timezone into cfg,tz from omg_private.online_connections c join public.properties p on p.id=c.property_id where c.property_id=prop;
 if not found then return;end if;
 cfg:=coalesce(cfg,'{"staff":{"enabled":false,"mode":"normal","scopes":["all"]},"owner":{"enabled":true,"mode":"normal","time_enabled":false,"from":"21:00","to":"09:00","no_staff_only":false,"scopes":["all"]}}');
 day:=(at_time at time zone coalesce(tz,'Asia/Seoul'))::date;local_time:=(at_time at time zone coalesce(tz,'Asia/Seoul'))::time;
 select b.arrival,b.departure into arrival,departure from omg_private.online_bookings b where b.property_id=prop and b.id=bid;
 select exists(select 1 from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=prop and e.property_id=prop and e.active and w.status='working' and w.checkin_report_at is not null and w.checkin_report_at<=at_time and w.checkout_report_at is null and w.token_expires_at>at_time) into has_staff;
 if coalesce((cfg->'staff'->>'enabled')::boolean,false) and omg_private.online_message_scope_matches(cfg->'staff'->'scopes',arrival,departure,day) then
  return query select distinct 'employee:'||e.id,'staff'::text,null::uuid,e.id,cfg->'staff'->>'mode' from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=prop and e.property_id=prop and e.active and w.status='working' and w.checkin_report_at is not null and w.checkin_report_at<=at_time and w.checkout_report_at is null and w.token_expires_at>at_time;
 end if;
 owner_allowed:=coalesce((cfg->'owner'->>'enabled')::boolean,false) and omg_private.online_message_scope_matches(cfg->'owner'->'scopes',arrival,departure,day);
 if owner_allowed and coalesce((cfg->'owner'->>'no_staff_only')::boolean,false) and has_staff then owner_allowed:=false;end if;
 if owner_allowed and coalesce((cfg->'owner'->>'time_enabled')::boolean,false) then
  window_from:=(cfg->'owner'->>'from')::time;window_to:=(cfg->'owner'->>'to')::time;
  owner_allowed:=case when window_from<window_to then local_time>=window_from and local_time<window_to else local_time>=window_from or local_time<window_to end;
 end if;
 if owner_allowed then return query select 'owner:'||o.id,'owner'::text,o.id,null::uuid,cfg->'owner'->>'mode' from public.owners o where o.property_id=prop and o.active;end if;
end$$;
revoke all on function omg_private.online_message_alert_recipients(uuid,bigint,timestamptz) from public,anon,authenticated;
grant execute on function omg_private.online_message_alert_recipients(uuid,bigint,timestamptz) to service_role;

do $patch$
declare f text;n text;begin
 f:=pg_get_functiondef('omg_private.save_online_message_alert_draft(uuid,jsonb)'::regprocedure);
 if strpos(f,'online_message_alert=result')=0 then
  n:='set online_message_alert_draft=result where property_id=prop';if strpos(f,n)=0 then raise exception '메시지 알림 저장 위치를 확인해주세요.';end if;
  f:=replace(f,n,'set online_message_alert=result,online_message_alert_draft=result where property_id=prop');
  f:=replace(f,'''online_message_alert_draft'',result,''pending'',true','''online_message_alert'',result,''online_message_alert_draft'',result,''pending'',false');
 end if;execute f;
 f:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,'''online_message_alert'',c.online_message_alert')=0 then
  n:='''online_message_alert_draft'',c.online_message_alert_draft';if strpos(f,n)=0 then raise exception '메시지 알림 조회 위치를 확인해주세요.';end if;
  f:=replace(f,n,'''online_message_alert'',c.online_message_alert,'||n);
  f:=replace(f,'p_action=''save_message_alert_draft''','p_action in(''save_message_alert'',''save_message_alert_draft'')');
 end if;execute f;
 f:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);
 if strpos(f,'online_message_alert_recipients(p_property,bid)')=0 then
  n:=E'    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)\n    select notice,''owner:''||o.id,''owner'',o.id from public.owners o where o.property_id=p_property and o.active;';
  if strpos(f,n)=0 then raise exception '온라인 메시지 수신 대상 위치를 확인해주세요.';end if;
  f:=replace(f,n,E'    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)\n    select notice,r.recipient_key,r.recipient_type,r.owner_id,r.employee_id from omg_private.online_message_alert_recipients(p_property,bid) r;');
  n:='and (x->>''time'')::timestamptz>=c.created_at then';if strpos(f,n)=0 then raise exception '온라인 메시지 생성 조건을 확인해주세요.';end if;
  f:=replace(f,n,'and (x->>''time'')::timestamptz>=c.created_at and exists(select 1 from omg_private.online_message_alert_recipients(p_property,bid)) then');
 end if;execute f;
end $patch$;

-- Delivery rechecks current schedule, duty and scope without backfilling new recipients.
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
 select booking_id into bid from omg_private.online_messages where property_id=m.property_id and notice_id=m.id limit 1;
 if bid is null then return jsonb_build_object('ok',false);end if;
 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
  select 'property_'||m.management_number||case when t.recipient_type='owner' then '_owner_'||t.owner_id else '_employee_'||t.employee_id end topic,t.mode
  from omg_private.online_message_alert_recipients(m.property_id,bid) t join public.property_message_recipients r on r.message_id=m.id and r.recipient_key=t.recipient_key and r.recipient_type=t.recipient_type and r.owner_id is not distinct from t.owner_id and r.employee_id is not distinct from t.employee_id
 )x;
 return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-ONLINE:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'route','online.html#thread/'||(select booking_id from omg_private.online_messages where notice_id=m.id limit 1)||'?property='||m.property_id);
end$$;
revoke all on function public.get_online_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_online_push_dispatch(uuid) to service_role;
