alter table omg_private.briefing_deliveries
 alter column employee_id drop not null,
 add column owner_id uuid references public.owners(id) on delete cascade,
 add constraint briefing_delivery_one_recipient check(num_nonnulls(employee_id,owner_id)=1),
 add constraint briefing_delivery_owner_unique unique(run_id,owner_id);

create function omg_private.briefing_owner_is_eligible(p_source uuid,p_owner uuid)
returns boolean language sql stable set search_path='' as $$
 select exists(select from public.owners o where o.id=p_owner and o.active
  and omg_private.briefing_can_receive(p_source,o.property_id))
$$;
revoke all on function omg_private.briefing_owner_is_eligible(uuid,uuid) from public,anon,authenticated;

do $migration$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 if strpos(definition,'jsonb_array_length(data->''notify_targets'') not between 1 and 1000')=0 then
  raise exception 'Missing briefing target validation';
 end if;
 definition:=replace(definition,'jsonb_array_length(data->''notify_targets'') not between 1 and 1000','jsonb_array_length(data->''notify_targets'')>1000');
 definition:=replace(definition,$hook$value not in ('all','reservation','onsite','cleaning') and not exists($hook$,
  $hook$value not in ('all','reservation','onsite','cleaning') and value !~ '^skip-owner:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' and not exists($hook$);
 anchor:=$hook$   if not exists(
    select 1 from public.employees e$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing preview audience check';end if;
 definition:=replace(definition,anchor,$hook$   if not exists(
    select from public.owners o where o.active and omg_private.briefing_can_receive(prop,o.property_id)
     and (o.property_id=prop or not ((data->'notify_targets') ? ('skip-owner:'||o.id)))
   ) and not exists(
    select 1 from public.employees e$hook$);
 anchor:=$hook$ 'employees',(select coalesce$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing roster';end if;
 definition:=replace(definition,anchor,$hook$ 'shared_owners',(select coalesce(jsonb_agg(jsonb_build_object(
   'id',o.id,'name',o.display_name,'property_name',p.name) order by p.name,o.display_name,o.id),'[]')
   from public.owners o join public.properties p on p.id=o.property_id
   where o.active and o.property_id<>prop and omg_private.briefing_can_receive(prop,o.property_id)),
 'employees',(select coalesce$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_enqueue_delivery(omg_private.briefing_runs)'::regprocedure);
 anchor:=$hook$ on conflict(run_id,employee_id) do nothing$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing enqueue statement';end if;
 definition:=replace(definition,anchor,$hook$ on conflict(run_id,employee_id) do nothing;
 insert into omg_private.briefing_deliveries(run_id,owner_id,due_at)
 select run.id,o.id,case
  when run.mode='manual' or run.settings->>'notify_kind' is distinct from 'time' then now()
  else (local_end::date + (run.settings->>'notify_time')::time
   + case when (run.settings->>'notify_time')::time<date_trunc('minute',local_end)::time then interval '1 day' else interval '0' end)
    at time zone run.timezone end
 from public.owners o
 cross join lateral (select run.period_end at time zone run.timezone as local_end) bounds
 where o.active and omg_private.briefing_can_receive(run.property_id,o.property_id)
  and (o.property_id=run.property_id or not coalesce((run.settings->'notify_targets') ? ('skip-owner:'||o.id),false))
 on conflict(run_id,owner_id) do nothing
$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='join public.employees e on e.id=d.employee_id';
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing release join';end if;
 definition:=replace(definition,anchor,'left join public.employees e on e.id=d.employee_id');
 definition:=replace(definition,'d.id,d.employee_id,r.id','d.id,d.employee_id,d.owner_id,r.id');
 definition:=replace(definition,'where d.queued_at is null',
  'where (e.id is not null or omg_private.briefing_owner_is_eligible(r.property_id,d.owner_id)) and d.queued_at is null');
 anchor:=$hook$   insert into public.property_message_recipients(message_id,recipient_type,employee_id,recipient_key)
   values(message_id,'staff',delivery.employee_id,'employee:'||delivery.employee_id);$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing delivery recipient insert';end if;
 execute replace(definition,anchor,$hook$   if delivery.owner_id is not null then
    insert into public.property_message_recipients(message_id,recipient_type,owner_id,recipient_key)
    values(message_id,'owner',delivery.owner_id,'owner:'||delivery.owner_id);
   else
    insert into public.property_message_recipients(message_id,recipient_type,employee_id,recipient_key)
    values(message_id,'staff',delivery.employee_id,'employee:'||delivery.employee_id);
   end if;$hook$);
end
$migration$;

-- Administrator briefings use the bot's sending mode even outside staff
-- receive windows. Other notifications continue to use their existing rules.
create or replace function public.get_briefing_push_dispatch(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.property_messages%rowtype; mode text; name text; routes jsonb; route_modes jsonb; topics jsonb;
begin
 select * into m from public.property_messages where id=p_message_id and source='bot_briefing';
 if not found then return jsonb_build_object('ok',false);end if;
 select b.alert_mode,b.display_name into mode,name from public.notification_bots b where b.property_id=m.property_id;
 mode:=coalesce(mode,'normal');name:=coalesce(name,'OMS 알림');
 routes:=omg_private.bot_recipient_modes(m.id,mode);
 route_modes:=coalesce(routes->'recipient_modes','{}')||coalesce((
  select jsonb_object_agg('property_'||p.management_number||'_owner_'||o.id,mode)
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id
  join public.properties p on p.id=o.property_id where r.message_id=m.id
   and omg_private.briefing_owner_is_eligible(m.property_id,o.id)
 ),'{}');
 -- Remove revoked owner routes even if the shared bot recipient helper returned them.
 select coalesce(jsonb_object_agg(topic,level),'{}') into route_modes
 from jsonb_each(route_modes) x(topic,level)
 where topic not like '%_owner_%' or exists(
  select from public.property_message_recipients r join public.owners o on o.id=r.owner_id
   join public.properties p on p.id=o.property_id
  where r.message_id=m.id and topic='property_'||p.management_number||'_owner_'||o.id
   and omg_private.briefing_owner_is_eligible(m.property_id,o.id)
 );
 select coalesce(jsonb_agg(topic),'[]') into topics from jsonb_object_keys(route_modes) x(topic);
 return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'sender_label',name||' · 브리핑',
  'priority',case when mode='urgent' then 'urgent' else 'normal' end,'recipient_modes',route_modes,'recipient_topics',topics);
end$$;
revoke all on function public.get_briefing_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_briefing_push_dispatch(uuid) to service_role;
