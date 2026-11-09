-- Cron and Edge use one authoritative worker secret; it is never returned to callers.
create or replace function omg_private.verify_notification_worker(p_secret text)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(length(p_secret) between 1 and 4096 and exists(
  select 1 from vault.decrypted_secrets s where s.name='omg_guest_email_worker_secret'
   and length(s.decrypted_secret)>0
   and sha256(convert_to(s.decrypted_secret,'UTF8'))=sha256(convert_to(p_secret,'UTF8'))
 ),false)
$$;
revoke all on function omg_private.verify_notification_worker(text) from public,anon,authenticated;
grant usage on schema omg_private to service_role;
grant execute on function omg_private.verify_notification_worker(text) to service_role;
create or replace function public.verify_notification_worker(p_secret text)
returns boolean language sql stable security invoker set search_path='' as $$
 select omg_private.verify_notification_worker(p_secret)
$$;
revoke all on function public.verify_notification_worker(text) from public,anon,authenticated;
grant execute on function public.verify_notification_worker(text) to service_role;

-- A retry must not alert a recipient who has already read (or left) the chat.
CREATE OR REPLACE FUNCTION public.get_chat_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;v_bot_mode text;v_bot_name text;v_is_bot boolean;
begin
 if exists(select 1 from public.property_messages where id=p_message_id and source='work_confirmation') then
  if not exists(select 1 from omg_private.work_confirmations c join public.work_sessions w on w.id=c.work_session_id
   where c.id=p_message_id and c.confirmed_at is null and c.ended_at is null and c.cancelled_at is null and c.deadline_at>clock_timestamp() and w.status='working') then
   return jsonb_build_object('ok',true,'recipient_topics','[]'::jsonb,'recipient_modes','{}'::jsonb,'message_id',p_message_id,'message','근무 확인 종료');
  end if;
  select jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'message_type','work_confirmation',
   'sender_label','근무 12시간 초과 알림','priority','normal','recipient_topics',jsonb_build_array('property_'||p.management_number||'_employee_'||r.employee_id),
   'recipient_modes',jsonb_build_object('property_'||p.management_number||'_employee_'||r.employee_id,'normal')) into v_payload
  from public.property_messages m join public.property_message_recipients r on r.message_id=m.id
   join public.properties p on p.id=m.property_id where m.id=p_message_id;
  return v_payload;
 end if;
 v_payload:=omg_private.chat_push_payload(p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]',coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림')
 into v_is_bot,v_bot_mode,v_bot_name from public.property_messages m left join public.notification_bots b on b.property_id=m.property_id where m.id=p_message_id;
 if not coalesce(v_is_bot,false) then v_bot_mode:=null;end if;

 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and r.read_at is null and e.active
  and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions ws where ws.employee_id=e.id and ws.status='working' and ws.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and r.read_at is null and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then coalesce(active.alert_mode,'urgent') else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
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
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$function$;
revoke all on function public.get_chat_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_chat_push_dispatch(uuid) to service_role;
