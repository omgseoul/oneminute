-- Only the report author can request push delivery. Recipients are resolved on the server.
begin;
create or replace function public.get_report_push_dispatch(p_access_token uuid,p_report_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor jsonb;report_row public.work_reports%rowtype;topics jsonb;
begin
 actor:=omg_private.guest_actor(p_access_token);
 if actor is null or actor->>'kind'<>'staff' then return jsonb_build_object('ok',false,'code','invalid_session');end if;
 select * into report_row from public.work_reports where id=p_report_id and employee_id=(actor->>'id')::uuid
 and property_id=(actor->>'property_id')::uuid;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 with recipients as (
  select o.id owner_id,o.property_id home_property,p.management_number,n.schedules
  from public.owners o join public.properties p on p.id=o.property_id
  left join public.guest_chat_alert_preferences n on n.actor_key='owner:'||o.id
  where o.active and omg_private.guest_can_access(o.property_id,report_row.property_id)
 ), eligible as (
  select 'property_'||r.management_number||'_owner_'||r.owner_id topic
  from recipients r
  where r.schedules is null or exists (
    select 1 from jsonb_array_elements(r.schedules) s
    cross join lateral (select now() at time zone p.timezone local_time from public.properties p where p.id=r.home_property) local
    where coalesce((s->>'enabled')::boolean,false)
    and report_row.property_id=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
    and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.local_time::time<(s->>'end_time')::time
      then extract(dow from local.local_time-interval '1 day')::int else extract(dow from local.local_time)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
    and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.local_time::time>=(s->>'start_time')::time and local.local_time::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.local_time::time>=(s->>'start_time')::time or local.local_time::time<(s->>'end_time')::time)))
  )
 )
 select coalesce(jsonb_agg(distinct topic),'[]'::jsonb) into topics from eligible;
 return jsonb_build_object('ok',true,'report_id',report_row.id,'recipient_topics',topics,
  'message',case when report_row.report_type='clock_in' then '출근보고' else '퇴근보고' end||' '||coalesce(report_row.payload->>'worker','근무자'),
  'report_type',report_row.report_type);
end;$$;
revoke all on function public.get_report_push_dispatch(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_report_push_dispatch(uuid,uuid) to service_role;
commit;
