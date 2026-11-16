-- Account-level fields and maximum strength, shared by push and popup routes.
begin;
create or replace function omg_private.staff_alert_mode(actor text, prop uuid, field text, requested text, at_time timestamptz default now())
returns text language plpgsql stable security definer set search_path='' as $$
declare pref public.guest_chat_alert_preferences%rowtype;tz text;local_at timestamp;cap integer;requested_rank integer;
begin
 if actor not like 'employee:%' then return requested;end if;
 if not exists(select 1 from public.employees e where 'employee:'||e.id=actor and e.active and omg_private.guest_can_access(e.property_id,prop)) then return null;end if;
 requested_rank:=array_position(array['weak','normal','strong','urgent'],requested);
 if requested_rank is null then return null;end if;
 select * into pref from public.guest_chat_alert_preferences where actor_key=actor;
 if not found then return requested;end if;
 select timezone into tz from public.properties where id=pref.home_property_id;
 local_at:=at_time at time zone coalesce(tz,'Asia/Seoul');
 select max(array_position(array['weak','normal','strong','urgent'],s->>'alert_mode')) into cap
 from jsonb_array_elements(case when jsonb_array_length(coalesce(pref.schedules,'[]'))>0 then pref.schedules else jsonb_build_array(jsonb_build_object('enabled',pref.enabled,'alert_mode',pref.alert_mode,'property_ids',pref.property_ids,'days',pref.days,'start_time',pref.start_time,'end_time',pref.end_time)) end)s
 where coalesce((s->>'enabled')::boolean,false)
 and (field is null or coalesce(s->'fields','["onsite_guest","online_guest","same_day_booking"]'::jsonb)?field)
 and prop=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
 and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local_at::time<(s->>'end_time')::time then extract(dow from local_at-interval '1 day')::int else extract(dow from local_at)::int end)=any(array(select value::int from jsonb_array_elements_text(s->'days')))
 and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
 or ((s->>'start_time')::time<(s->>'end_time')::time and local_at::time>=(s->>'start_time')::time and local_at::time<(s->>'end_time')::time)
 or ((s->>'start_time')::time>(s->>'end_time')::time and (local_at::time>=(s->>'start_time')::time or local_at::time<(s->>'end_time')::time)));
 if cap is null then return null;end if;
 return (array['weak','normal','strong','urgent'])[least(cap,requested_rank)];
end$$;
revoke all on function omg_private.staff_alert_mode(text,uuid,text,text,timestamptz) from public,anon,authenticated;

create or replace function omg_private.filter_staff_dispatch(payload jsonb,prop uuid,field text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare topic text;actor text;mode text;topics jsonb:='[]';modes jsonb:='{}';deadlines jsonb:='{}';
begin
 for topic in select value from jsonb_array_elements_text(coalesce(payload->'recipient_topics','[]')) loop
  mode:=coalesce(payload->'recipient_modes'->>topic,'urgent');
  if topic like '%_employee_%' then
   select 'employee:'||e.id into actor from public.employees e join public.properties p on p.id=e.property_id where topic='property_'||p.management_number||'_employee_'||e.id and e.active;
   mode:=case when actor is not null then omg_private.staff_alert_mode(actor,prop,field,mode) end;
  end if;
  if mode is not null then
   topics:=topics||jsonb_build_array(topic);modes:=modes||jsonb_build_object(topic,mode);
   if payload->'recipient_deadlines'?topic then deadlines:=deadlines||jsonb_build_object(topic,payload->'recipient_deadlines'->topic);end if;
  end if;
 end loop;
 return payload||jsonb_build_object('recipient_topics',topics,'recipient_modes',modes,'recipient_deadlines',deadlines);
end$$;
revoke all on function omg_private.filter_staff_dispatch(jsonb,uuid,text) from public,anon,authenticated;

create or replace function omg_private.staff_message_popup_mode(mid uuid,eid uuid)
returns text language plpgsql stable security definer set search_path='' as $$
declare m public.property_messages%rowtype;cfg jsonb;requested text;field text;
begin
 select * into m from public.property_messages where id=mid;
 if not found then return null;end if;
 if m.source='beds24' then
  select t.mode into requested from omg_private.online_messages om cross join lateral omg_private.online_message_alert_recipients(m.property_id,om.booking_id)t where om.notice_id=m.id and om.property_id=m.property_id and t.employee_id=eid limit 1;
  return requested;
 elsif m.source='beds24_booking' then
  select same_day_alert into cfg from omg_private.online_connections where property_id=m.property_id;
  if not coalesce((cfg->>'enabled')::boolean,false) or not coalesce((cfg->>'notify_staff')::boolean,false) then return null;end if;
  requested:=cfg->>'staff_mode';field:='same_day_booking';
 elsif m.source='guest_ai' then
  select case when a.urgent then s.emergency_config else s.handoff_config end into cfg from omg_private.ai_alerts a join omg_private.ai_settings s on s.property_id=m.property_id where a.event_id=m.external_message_id::uuid;
  if not coalesce((cfg->>'enabled')::boolean,false) or not coalesce((cfg->>'notify_staff')::boolean,false) then return null;end if;
  requested:=cfg->>'staff_mode';field:='onsite_guest';
 else return 'urgent';end if;
 return omg_private.staff_alert_mode('employee:'||eid,m.property_id,field,requested);
end$$;
revoke all on function omg_private.staff_message_popup_mode(uuid,uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.save_guest_chat_alert_schedules(p_access_token uuid, p_actor_key text, p_schedules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare home uuid;item jsonb;normalized jsonb:='[]'::jsonb;first_rule jsonb;
 props uuid[];rule_days integer[];st time;et time;rule_id uuid;mode text;fields jsonb;old_schedules jsonb;
begin
 select o.property_id into home from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token)
 and s.token_expires_at>clock_timestamp() and o.active;
 if home is null then raise exception '관리자 로그인이 필요합니다.';end if;
 if not exists(select 1 from public.employees where 'employee:'||id=p_actor_key and property_id=home and active)
 and not exists(select 1 from public.owners where 'owner:'||id=p_actor_key and property_id=home and active)
 then raise exception '자기 지점 계정만 설정할 수 있습니다.';end if;
 if jsonb_typeof(p_schedules)<>'array' or jsonb_array_length(p_schedules) not between 1 and 8
 then raise exception '알림 설정은 1개부터 8개까지 저장할 수 있습니다.';end if;
 select schedules into old_schedules from public.guest_chat_alert_preferences where actor_key=p_actor_key;
 for item in select value from jsonb_array_elements(p_schedules) loop
  rule_id:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
  fields:=coalesce(item->'fields',(select old->'fields' from jsonb_array_elements(old_schedules)old where old->>'id'=rule_id::text),'["onsite_guest","online_guest","same_day_booking"]'::jsonb);
  if jsonb_typeof(fields)<>'array' then raise exception '알림 허용 분야를 확인해주세요.';end if;
  if exists(select 1 from jsonb_array_elements_text(fields)x where x not in('onsite_guest','online_guest','same_day_booking')) then raise exception '알림 허용 분야를 확인해주세요.';end if;
  mode:=coalesce(item->>'alert_mode','urgent');
  if mode not in ('weak','normal','strong','urgent') then raise exception '알림 방식을 선택해주세요.';end if;
  select coalesce(array_agg(value::uuid),'{}') into props from jsonb_array_elements_text(coalesce(item->'property_ids','[]'::jsonb));
  if coalesce((item->>'enabled')::boolean,false) and cardinality(props)=0 then raise exception '알림 받을 지점을 선택해주세요.';end if;
  if exists(select 1 from unnest(props)x where not omg_private.guest_can_access(home,x)) then raise exception '공유 승인된 지점만 선택할 수 있습니다.';end if;
  select coalesce(array_agg(value::integer),'{}') into rule_days from jsonb_array_elements_text(coalesce(item->'days','[]'::jsonb));
  if not rule_days<@array[0,1,2,3,4,5,6] or cardinality(rule_days)=0 then raise exception '알림 요일을 선택해주세요.';end if;
  st:=nullif(item->>'start_time','')::time;et:=nullif(item->>'end_time','')::time;
  if (st is null)<>(et is null) then raise exception '시작·종료 시간을 모두 입력해주세요.';end if;
  normalized:=normalized||jsonb_build_array(jsonb_build_object(
   'fields',fields,'id',rule_id,'enabled',coalesce((item->>'enabled')::boolean,false),'alert_mode',mode,
   'property_ids',to_jsonb(props),'days',to_jsonb(rule_days),
   'start_time',coalesce(to_char(st,'HH24:MI'),''),'end_time',coalesce(to_char(et,'HH24:MI'),'')));
 end loop;
 first_rule:=normalized->0;
 insert into public.guest_chat_alert_preferences(actor_key,home_property_id,enabled,property_ids,days,start_time,end_time,alert_mode,schedules)
 values(p_actor_key,home,(first_rule->>'enabled')::boolean,
  array(select value::uuid from jsonb_array_elements_text(first_rule->'property_ids')),
  array(select value::integer from jsonb_array_elements_text(first_rule->'days')),
  nullif(first_rule->>'start_time','')::time,nullif(first_rule->>'end_time','')::time,
  first_rule->>'alert_mode',normalized)
 on conflict(actor_key) do update set enabled=excluded.enabled,property_ids=excluded.property_ids,
  days=excluded.days,start_time=excluded.start_time,end_time=excluded.end_time,
  alert_mode=excluded.alert_mode,schedules=excluded.schedules,updated_at=now()
 where guest_chat_alert_preferences.home_property_id=home;
 return jsonb_build_object('ok',true,'schedules',normalized);
end$function$

;

CREATE OR REPLACE FUNCTION omg_private.online_message_alert_recipients(prop uuid, bid bigint, at_time timestamp with time zone DEFAULT now())
 RETURNS TABLE(recipient_key text, recipient_type text, owner_id uuid, employee_id uuid, mode text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare cfg jsonb;tz text;day date;local_time time;arrival date;departure date;has_staff boolean;owner_allowed boolean;window_from time;window_to time;begin
 select c.online_message_alert,p.timezone into cfg,tz from omg_private.online_connections c join public.properties p on p.id=c.property_id where c.property_id=prop;
 if not found then return;end if;
 cfg:=coalesce(cfg,'{"staff":{"enabled":false,"mode":"normal","scopes":["all"]},"owner":{"enabled":true,"mode":"normal","time_enabled":false,"from":"21:00","to":"09:00","no_staff_only":false,"scopes":["all"]}}');
 day:=(at_time at time zone coalesce(tz,'Asia/Seoul'))::date;local_time:=(at_time at time zone coalesce(tz,'Asia/Seoul'))::time;
 select b.arrival,b.departure into arrival,departure from omg_private.online_bookings b where b.property_id=prop and b.id=bid;
 select exists(select 1 from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=prop and e.property_id=prop and e.active and w.status='working' and w.checkin_report_at is not null and w.checkin_report_at<=at_time and w.checkout_report_at is null and w.token_expires_at>at_time) into has_staff;
 if coalesce((cfg->'staff'->>'enabled')::boolean,false) and omg_private.online_message_scope_matches(cfg->'staff'->'scopes',arrival,departure,day) then
  return query select distinct 'employee:'||e.id,'staff'::text,null::uuid,e.id,allowed.mode from public.work_sessions w join public.employees e on e.id=w.employee_id cross join lateral(select omg_private.staff_alert_mode('employee:'||e.id,prop,'online_guest',cfg->'staff'->>'mode',at_time) mode)allowed where allowed.mode is not null and w.property_id=prop and e.property_id=prop and e.active and w.status='working' and w.checkin_report_at is not null and w.checkin_report_at<=at_time and w.checkout_report_at is null and w.token_expires_at>at_time;
 end if;
 owner_allowed:=coalesce((cfg->'owner'->>'enabled')::boolean,false) and omg_private.online_message_scope_matches(cfg->'owner'->'scopes',arrival,departure,day);
 if owner_allowed and coalesce((cfg->'owner'->>'no_staff_only')::boolean,false) and has_staff then owner_allowed:=false;end if;
 if owner_allowed and coalesce((cfg->'owner'->>'time_enabled')::boolean,false) then
  window_from:=(cfg->'owner'->>'from')::time;window_to:=(cfg->'owner'->>'to')::time;
  owner_allowed:=case when window_from<window_to then local_time>=window_from and local_time<window_to else local_time>=window_from or local_time<window_to end;
 end if;
 if owner_allowed then return query select 'owner:'||o.owner_id,'owner'::text,o.owner_id,null::uuid,cfg->'owner'->>'mode' from omg_private.booking_alert_owners(prop) o;end if;
end$function$

;

CREATE OR REPLACE FUNCTION public.get_online_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m record;topics jsonb;modes jsonb;cfg jsonb;bid bigint;begin
 select msg.*,p.management_number into m from public.property_messages msg join public.properties p on p.id=msg.property_id where msg.id=p_message_id and msg.source in('beds24','beds24_booking');
 if not found then return jsonb_build_object('ok',false);end if;
 if m.source='beds24_booking' then
  select same_day_alert into cfg from omg_private.online_connections where property_id=m.property_id;
  select booking_id into bid from omg_private.online_booking_notices where message_id=m.id and property_id=m.property_id;
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
   select o.topic,cfg->>'owner_mode' mode from public.property_message_recipients r join omg_private.booking_alert_owners(m.property_id) o on o.owner_id=r.owner_id where r.message_id=m.id and r.recipient_type='owner' and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_owner')::boolean,false)
   union select 'property_'||m.management_number||'_employee_'||r.employee_id,cfg->>'staff_mode' from public.property_message_recipients r join public.employees e on e.id=r.employee_id where r.message_id=m.id and r.recipient_type='staff' and e.active and e.property_id=m.property_id and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_staff')::boolean,false) and exists(select 1 from public.work_sessions w where w.employee_id=e.id and w.property_id=m.property_id and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now())
  )x;
  return omg_private.filter_staff_dispatch(jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-BOOKING:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'guest_context',omg_private.guest_popup_booking(m.property_id,m.id),'sender_label','당일 예약 발생','priority','normal','route','messages.html#bot'),m.property_id,'same_day_booking');
 end if;
 select booking_id into bid from omg_private.online_messages where property_id=m.property_id and notice_id=m.id limit 1;
 if bid is null then return jsonb_build_object('ok',false);end if;
 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
  select case when t.recipient_type='owner' then (select ao.topic from omg_private.booking_alert_owners(m.property_id) ao where ao.owner_id=t.owner_id) else 'property_'||m.management_number||'_employee_'||t.employee_id end topic,t.mode
  from omg_private.online_message_alert_recipients(m.property_id,bid) t join public.property_message_recipients r on r.message_id=m.id and r.recipient_key=t.recipient_key and r.recipient_type=t.recipient_type and r.owner_id is not distinct from t.owner_id and r.employee_id is not distinct from t.employee_id
 )x;
 return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-ONLINE:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'guest_context',omg_private.guest_popup_online(m.property_id,m.id),'route','online.html#thread/'||(select booking_id from omg_private.online_messages where notice_id=m.id limit 1)||'?property='||m.property_id);
end$function$

;

CREATE OR REPLACE FUNCTION public.get_guest_chat_dispatch(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;alert omg_private.ai_alerts%rowtype;cfg jsonb;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;

 -- AI handles ordinary questions silently; escalation has its own durable event.
 if ev.event_kind='message' and exists(select 1 from omg_private.ai_jobs where message_id=ev.message_id and status in('pending','leased','completed','handoff')) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb);end if;
 select * into alert from omg_private.ai_alerts where event_id=ev.id;

 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
  coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
  select distinct on(c.topic)c.topic,c.alert_mode,c.valid_until from(
   select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,case when n.actor_key like 'employee:%' and ev.event_kind='started' and s->>'alert_mode' in('strong','urgent') then 'normal' else s->>'alert_mode' end alert_mode,
    ((extract(epoch from least(ev.created_at+interval '5 minutes',
     (case when nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time' then (local.t::date+1)::timestamp
      when (s->>'start_time')::time>(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time then (local.t::date+1)+(s->>'end_time')::time
      else local.t::date+(s->>'end_time')::time end) at time zone p.timezone))*1000)::bigint)::text valid_until,
    case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end strength
   from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
   cross join lateral jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone p.timezone t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.property_id=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and omg_private.guest_can_access(n.home_property_id,r.property_id)
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   and (exists(select 1 from public.work_sessions ws join public.employees e on e.id=ws.employee_id where 'employee:'||e.id=n.actor_key and e.active and ws.status='working' and ws.token_expires_at>now())
    or exists(select 1 from public.owner_sessions os join public.owners o on o.id=os.owner_id where 'owner:'||o.id=n.actor_key and o.active and os.token_expires_at>now()))
  )c order by c.topic,c.strength desc,c.valid_until desc
 )x;
 if alert.event_id is not null then
  select case when alert.urgent then s.emergency_config else s.handoff_config end into cfg from omg_private.ai_settings s where s.property_id=r.property_id;
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from (
   select 'property_'||p.management_number||'_owner_'||o.id topic,cfg->>'owner_mode' mode
   from public.owners o join public.properties p on p.id=o.property_id
   where o.property_id=r.property_id and o.active and (cfg->>'enabled')::boolean and (cfg->>'notify_owner')::boolean
   union
   select 'property_'||p.management_number||'_employee_'||e.id,cfg->>'staff_mode'
   from public.work_sessions w join public.employees e on e.id=w.employee_id join public.properties p on p.id=w.property_id
   where w.property_id=r.property_id and e.property_id=r.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now()
    and (cfg->>'enabled')::boolean and (cfg->>'notify_staff')::boolean
  )x;
  deadlines:='{}'::jsonb;
  return omg_private.filter_staff_dispatch(jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_modes',modes,'recipient_deadlines',deadlines,'message_type','guest_chat','guest_context',omg_private.guest_popup_onsite(r.id,ev.created_at),'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,'priority',case when alert.urgent then 'urgent' else 'normal' end,'sender_label',case when alert.urgent then '긴급 AI 지원요청 · ' else 'AI 지원요청 · ' end||r.guest_name||' · '||coalesce(r.room_number,'객실 미정'),'message',alert.reason||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=alert.message_id),'')),r.property_id,'onsite_guest');
 end if;
 return omg_private.filter_staff_dispatch(jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat','guest_context',omg_private.guest_popup_onsite(r.id,ev.created_at),
  'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
  'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label',r.guest_name,
  'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.') end),r.property_id,'onsite_guest');
end$function$

;

CREATE OR REPLACE FUNCTION public.get_message_push_dispatch_v2(p_access_token uuid, p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;v_bot_mode text;v_bot_name text;v_is_bot boolean;
begin
 v_payload:=public.get_message_push_dispatch(p_access_token,p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]',coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림')
 into v_is_bot,v_bot_mode,v_bot_name from public.property_messages m left join public.notification_bots b on b.property_id=m.property_id where m.id=p_message_id;
 if not coalesce(v_is_bot,false) then v_bot_mode:=null;end if;

 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and e.active
  and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions ws where ws.employee_id=e.id and ws.status='working' and ws.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then (array['weak','normal','strong','urgent'])[least(case when v_payload->>'priority'='urgent' then 4 else 2 end,array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
  from recipients r left join public.guest_chat_alert_preferences n on n.actor_key=r.actor_key
  left join lateral(
   select s->>'alert_mode' alert_mode from jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone (select timezone from public.properties where id=n.home_property_id)t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.target_property=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   order by case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end desc limit 1
  )active on true
  where n.actor_key is null or active.alert_mode is not null
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from targets;
 if v_is_bot then v_payload:=v_payload||jsonb_build_object('sender_label',v_bot_name,'is_bot',true,'priority',case when v_bot_mode='urgent' then 'urgent' else 'normal' end);end if;
 if exists(select 1 from public.property_messages where id=p_message_id and source in('beds24','beds24_booking')) then return public.get_online_push_dispatch(p_message_id);end if;
 if exists(select 1 from public.property_messages where id=p_message_id and source='guest_ai') then return public.get_guest_chat_dispatch((select external_message_id::uuid from public.property_messages where id=p_message_id));end if;
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$function$

;

CREATE OR REPLACE FUNCTION public.list_property_messages(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property_id uuid;
  v_owner_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb:='[]'::jsonb;v_recipients jsonb:='[]'::jsonb;v_unread integer:=0;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;v_property_id:=v_owner_session.property_id;v_owner_id:=v_owner_session.owner_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    v_property_id:=v_work_session.property_id;v_employee_id:=v_work_session.employee_id;
  end if;
  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients from(
    select jsonb_build_object('recipient_key','owner:'||o.id,'recipient_type','owner','owner_id',o.id,
      'property_id',p.id,'property_name',p.name,'base_name',o.display_name,'profile_image',o.profile_image,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'property_name',p.name,'base_name',e.display_name,'profile_image',e.profile_image,'work_state',omg_private.target_work_state(e.id),'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
      'sort_key','1'||p.name||e.created_at::text)x from public.employees e join public.properties p on p.id=e.property_id
    where e.active and e.role<>'owner' and e.id<>coalesce(v_employee_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and(e.property_id=v_property_id or exists(select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id))))
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,r.acknowledged_at current_acknowledged_at,r.acknowledged_name current_acknowledged_name,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null)
      and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'guest_context',case when m.source='beds24' then omg_private.guest_popup_online(m.property_id,m.id) when m.source='beds24_booking' then omg_private.guest_popup_booking(m.property_id,m.id) else null end,'online_popup_allowed',case when m.source='beds24' then exists(select 1 from omg_private.online_messages om cross join lateral omg_private.online_message_alert_recipients(m.property_id,om.booking_id) target where om.property_id=m.property_id and om.notice_id=m.id and target.mode<>'weak' and ((v_is_owner and target.owner_id=v_owner_id) or (not v_is_owner and target.employee_id=v_employee_id))) else true end and (v_is_owner or m.source is null or m.source not in('beds24','beds24_booking','guest_ai') or coalesce(omg_private.staff_message_popup_mode(m.id,v_employee_id)<>'weak',false)),'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',case when m.source='work_confirmation' then 'work_confirmation' else m.message_type end,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.source='reminder' then case when m.message like 'To do 알림%' then 'To do 알림' else '일정 알림' end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at,'acknowledged_name',rr.acknowledged_name,'acknowledged_understood',rr.acknowledged_understood,'read_at',rr.read_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'holiday_request_id',m.holiday_request_id,'approval_status',coalesce(ar.status,psr.status,hr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date,'attendance_timezone',(select ap.timezone from public.properties ap where ap.id=ws.property_id)) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.holiday_requests hr on hr.id=m.holiday_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$function$

;

CREATE OR REPLACE FUNCTION public.home_message_summary(p_access_token uuid, p_data jsonb DEFAULT '{}'::jsonb, p_revision text DEFAULT NULL::text, p_include_alerts boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '12s'
AS $function$
declare a jsonb:=omg_private.guest_actor(p_access_token);g jsonb;rev text;alerts jsonb;
 reports jsonb:='[]';report_count bigint:=0;since_at timestamptz;answer jsonb;
begin
 if a is null then return jsonb_build_object('ok',false,'code','invalid_session');end if;
 g:=omg_private.guest_message_summary(p_access_token,p_data);
 if not coalesce((g->>'ok')::boolean,false) then return g;end if;
 if a->>'kind'='owner' then
  select started_at into since_at from omg_private.report_inbox_started where id;
  select count(*) into report_count from public.work_reports r
  where r.submitted_at>=since_at and omg_private.guest_can_access((a->>'property_id')::uuid,r.property_id)
   and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(a->>'id')::uuid);
  if p_include_alerts then
   select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]') into reports from (
    select r.id,r.submitted_at,jsonb_build_object('report_id',r.id,'report_type',r.report_type,'employee_name',coalesce(r.payload->>'worker',e.display_name),'unread',true) item
    from public.work_reports r join public.employees e on e.id=r.employee_id
    where r.submitted_at>=since_at and omg_private.guest_can_access((a->>'property_id')::uuid,r.property_id)
     and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(a->>'id')::uuid)
    order by r.submitted_at desc,r.id desc limit 50
   )x;
  end if;
 end if;
 answer:=jsonb_build_object('ok',true,'can_manage',a->>'kind'='owner','guest_unread',g->'unread',
  'messenger_unread',g->'messenger_unread','report_unread',report_count,
  'staff_unread',coalesce((g->>'messenger_unread')::bigint,0)+report_count);
 if not p_include_alerts then return answer;end if;
 -- Includes read/ack changes: a stable count alone cannot identify a new arrival.
 select md5(coalesce(string_agg(x.state,'|' order by x.created_at,x.id),'')) into rev from (
  select m.id,m.created_at,concat_ws(':',m.id,r.read_at,r.acknowledged_at,md5(m.message),m.priority,m.source,case when m.source='beds24' and r.read_at is null then md5(omg_private.guest_popup_online(m.property_id,m.id)::text) end) state
  from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.recipient_key=a->>'key' order by m.created_at desc,m.id desc limit 150
 )x;
 -- Include account eligibility in revision so saved choices invalidate an open home screen.
 if a->>'kind'<>'owner' then
  rev:=md5(rev||coalesce((select schedules::text from public.guest_chat_alert_preferences where actor_key=a->>'key'),'')||to_char(now(),'YYYY-MM-DD HH24:MI'));
 end if;
 answer:=answer||jsonb_build_object('revision',rev,'messages_changed',rev is distinct from p_revision,'reports',reports);
 if rev is distinct from p_revision then
  -- The established inbox supplies popup eligibility and shared-branch context.
  -- This expensive projection runs only after a change, never for native badge reads.
  select coalesce(jsonb_agg(item-'announcement_acknowledgements'-'recipient_labels' order by ord),'[]') into alerts
  from jsonb_array_elements(public.list_property_messages(p_access_token)->'messages') with ordinality t(item,ord)
  where not coalesce((item->>'is_sender')::boolean,false) and item->>'read_at' is null;
  answer:=answer||jsonb_build_object('messages',alerts);
 end if;
 return answer;
end $function$

;
commit;
