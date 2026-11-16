-- Keep inbox filters and authorization identical; never ship profiles/history for badges.
begin;
create or replace function public.home_message_summary(
 p_access_token uuid,p_data jsonb default '{}',p_revision text default null,p_include_alerts boolean default false
) returns jsonb language plpgsql security definer set search_path='' set statement_timeout='12s' as $$
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
end $$;
revoke all on function public.home_message_summary(uuid,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function public.home_message_summary(uuid,jsonb,text,boolean) to anon,authenticated,service_role;
notify pgrst, 'reload schema';
commit;
