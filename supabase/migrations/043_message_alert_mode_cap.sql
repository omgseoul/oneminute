-- Apply each recipient account's configured alert level as the maximum strength
-- for owner/staff messages as well as guest chat notifications.
begin;

create or replace function public.get_message_push_dispatch_v2(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;
begin
 v_payload:=public.get_message_push_dispatch(p_access_token,p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 with targets as (
  select 'property_'||p.management_number||'_employee_'||e.id as topic,
   coalesce(a.alert_mode,'urgent') as alert_mode
   from public.property_message_recipients r join public.employees e on e.id=r.employee_id
   join public.properties p on p.id=e.property_id
   left join public.guest_chat_alert_preferences a on a.actor_key='employee:'||e.id
   where r.message_id=p_message_id and e.active
   and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions s
     where s.employee_id=e.id and s.status='working' and s.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,
   coalesce(a.alert_mode,'urgent')
   from public.property_message_recipients r join public.owners o on o.id=r.owner_id
   join public.properties p on p.id=o.property_id
   left join public.guest_chat_alert_preferences a on a.actor_key='owner:'||o.id
   where r.message_id=p_message_id and o.active
 ), unique_targets as (
  select topic,max(alert_mode) alert_mode from targets group by topic
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),
  coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from unique_targets;
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$$;

revoke all on function public.get_message_push_dispatch_v2(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_message_push_dispatch_v2(uuid,uuid) to service_role;
commit;

select 'message alert mode cap installed' as migration_status;
