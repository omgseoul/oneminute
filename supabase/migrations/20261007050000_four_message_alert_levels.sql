-- Four notification levels. Preserve existing intent while inserting a new quiet level:
-- old weak -> normal, old normal -> strong, urgent -> urgent.
begin;

alter table public.guest_chat_alert_preferences
  drop constraint if exists guest_chat_alert_preferences_alert_mode_check;
alter table public.guest_chat_alert_preferences
  add constraint guest_chat_alert_preferences_alert_mode_check
  check(alert_mode in ('weak','normal','strong','urgent'));

update public.guest_chat_alert_preferences n
set alert_mode=case n.alert_mode when 'weak' then 'normal' when 'normal' then 'strong' else n.alert_mode end,
 schedules=coalesce((select jsonb_agg(jsonb_set(s.value,'{alert_mode}',to_jsonb(
   case s.value->>'alert_mode' when 'weak' then 'normal' when 'normal' then 'strong'
   when 'urgent' then 'urgent' else 'weak' end),true) order by s.ordinality)
   from jsonb_array_elements(n.schedules) with ordinality s(value,ordinality)),'[]'::jsonb);

create or replace function public.save_guest_chat_alert_schedules(
  p_access_token uuid,p_actor_key text,p_schedules jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare home uuid;item jsonb;normalized jsonb:='[]'::jsonb;first_rule jsonb;
 props uuid[];rule_days integer[];st time;et time;rule_id uuid;mode text;
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
 for item in select value from jsonb_array_elements(p_schedules) loop
  rule_id:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
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
   'id',rule_id,'enabled',coalesce((item->>'enabled')::boolean,false),'alert_mode',mode,
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
end$$;
revoke all on function public.save_guest_chat_alert_schedules(uuid,text,jsonb) from public;
grant execute on function public.save_guest_chat_alert_schedules(uuid,text,jsonb) to anon,authenticated;

create or replace function public.get_guest_chat_dispatch(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;
 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
  coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
  select distinct on(c.topic)c.topic,c.alert_mode,c.valid_until from(
   select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,s->>'alert_mode' alert_mode,
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
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat',
  'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
  'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label',r.guest_name,
  'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.') end);
end$$;
revoke all on function public.get_guest_chat_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_guest_chat_dispatch(uuid) to service_role;

create or replace function public.get_message_push_dispatch_v2(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;
begin
 v_payload:=public.get_message_push_dispatch(p_access_token,p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
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
  select r.topic,coalesce(active.alert_mode,'urgent')alert_mode
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
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$$;
revoke all on function public.get_message_push_dispatch_v2(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_message_push_dispatch_v2(uuid,uuid) to service_role;

commit;
