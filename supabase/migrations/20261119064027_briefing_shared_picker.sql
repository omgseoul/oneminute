-- A receiving branch may receive a source branch's briefing only while it
-- has an approved grant to read that source branch's messages.
create function omg_private.briefing_can_receive(p_source uuid,p_recipient uuid)
returns boolean language sql stable set search_path='' as $$
 select p_source=p_recipient or exists(
  select 1 from public.property_share_requests s
  where s.requester_property_id=p_recipient and s.target_property_id=p_source
    and s.status='approved' and 'messages'=any(s.requested_permissions)
 )
$$;
revoke all on function omg_private.briefing_can_receive(uuid,uuid) from public,anon,authenticated;

do $migration$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 anchor:='e.id::text=value and e.property_id=prop';
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing employee validation';end if;
 definition:=replace(definition,anchor,'e.id::text=value and omg_private.briefing_can_receive(prop,e.property_id)');
 anchor:=$hook$'employees',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name) order by e.display_name,e.id),'[]') from public.employees e where e.property_id=prop and e.active and e.role<>'owner')$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing roster';end if;
 definition:=replace(definition,anchor,$hook$
 'properties',(select coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'name',case when p.id=prop then '본점 · ' else '타지점 · ' end||p.name,
   'management_number',p.management_number) order by (p.id=prop) desc,p.name),'[]')
   from public.properties p where omg_private.briefing_can_receive(prop,p.id)),
 'employees',(select coalesce(jsonb_agg(jsonb_build_object(
   'id',e.id,'name',e.display_name,'property_id',e.property_id,
   'property_name',case when p.id=prop then '본점 · ' else '타지점 · ' end||p.name,
   'work_state',omg_private.target_work_state(e.id))
   order by (p.id=prop) desc,p.name,e.display_name,e.id),'[]')
   from public.employees e join public.properties p on p.id=e.property_id
   where omg_private.briefing_can_receive(prop,e.property_id) and e.active and e.role<>'owner')$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_enqueue_delivery(omg_private.briefing_runs)'::regprocedure);
 anchor:=$hook$e.property_id=run.property_id
   and (run.settings->'notify_targets' ? 'all'
    or run.settings->'notify_targets' ? e.id::text
    or (run.settings->'notify_targets') ?| e.duty_roles)$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing recipient selection';end if;
 definition:=replace(definition,anchor,$hook$omg_private.briefing_can_receive(run.property_id,e.property_id)
   and (run.settings->'notify_targets' ? e.id::text
    or (e.property_id=run.property_id and (run.settings->'notify_targets' ? 'all'
      or (run.settings->'notify_targets') ?| e.duty_roles)))$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='e.property_id=r.property_id';
 if strpos(definition,anchor)=0 or strpos(definition,'w.property_id=r.property_id')=0 then
  raise exception 'Missing briefing delivery property checks';
 end if;
 definition:=replace(definition,anchor,'omg_private.briefing_can_receive(r.property_id,e.property_id)');
 definition:=replace(definition,'w.property_id=r.property_id','w.property_id=e.property_id');
 execute definition;
end
$migration$;
