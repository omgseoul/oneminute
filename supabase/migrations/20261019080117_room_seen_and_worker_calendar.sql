begin;

CREATE OR REPLACE FUNCTION public.mark_property_message_read(p_access_token uuid, p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s
    join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  -- Seeing a message is independent of acknowledgement, signature or approval.
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.id=p_message_id
    and((v_owner_id is not null and r.owner_id=v_owner_id)or(v_employee_id is not null and r.employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.staff_chat_rpc(p_access_token uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';answer jsonb;stamp timestamptz;confirmed jsonb;seen_at timestamptz;seen_id uuid;changed_count integer;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='leave' then
  if peerkey is null or peerkey!~'^(owner|employee):[0-9a-f-]{36}$' or peerkey=actor then raise exception '대화를 찾을 수 없습니다.';end if;
  perform pg_advisory_xact_lock(hashtextextended(actor||':'||peerkey,71));
  if not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
   return jsonb_build_object('ok',true,'already_left',true);
  end if;
  stamp:=clock_timestamp();
  update public.property_message_recipients r set read_at=coalesce(r.read_at,stamp)
  where r.recipient_key=actor and exists(select 1 from omg_private.staff_conversation_items(actor)i
    where i.peer=peerkey and not i.mine and i.id=r.message_id and i.created_at<=stamp);
  insert into omg_private.staff_chat_departures values(actor,peerkey,stamp)
  on conflict(actor_key,peer) do update set left_at=excluded.left_at;
  insert into omg_private.staff_chat_events(actor_key,peer,actor_name,created_at) values(actor,peerkey,coalesce(a->>'name','근무자'),stamp);
  return jsonb_build_object('ok',true);
 end if;
 if p_action='read_room' then
  -- The opened room snapshot may end with our own replies/stickers. Its cursor
  -- acknowledges prior incoming history too, without touching later arrivals.
  select i.created_at,i.id into seen_at,seen_id from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and i.id=(p_data->>'through_id')::uuid;
  if seen_id is null then raise exception '확인한 대화 위치를 찾을 수 없습니다.';end if;
  update public.property_message_recipients r set read_at=clock_timestamp()
  where r.recipient_key=actor and r.read_at is null and exists(
   select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine
    and i.id=r.message_id and (i.created_at,i.id)<=(seen_at,seen_id));
  get diagnostics changed_count=row_count;
  return jsonb_build_object('ok',true,'read_count',changed_count,'read_through_id',seen_id,'read_through_at',seen_at,
   'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 end if;
 answer:=omg_private.staff_chat_core(p_access_token,p_action,p_data);
 if p_action='read' then
  select coalesce(jsonb_agg(i.id),'[]'::jsonb) into confirmed from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and not i.mine and i.read_at is not null and i.id in(
    select value::uuid from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb)));
  return answer||jsonb_build_object('read_ids',confirmed,'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 elsif p_action='messages' then
  return jsonb_set(answer,'{messages}',coalesce((select jsonb_agg(item||jsonb_build_object('system',exists(
    select 1 from omg_private.staff_chat_events ev where ev.id=(item->>'id')::uuid)) order by ordinal)
    from jsonb_array_elements(answer->'messages') with ordinality as rows(item,ordinal)),'[]'::jsonb));
 end if;
 return answer;
end $function$
;
create or replace function public.mark_notification_bot_seen(p_access_token uuid,p_through_message_id uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare a jsonb;actor text;seen_at timestamptz;seen_id uuid;changed_count integer;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 select m.created_at,m.id into seen_at,seen_id from public.property_messages m
 where m.id=p_through_message_id and (
   m.sender_type='system' or m.message_type in('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]')
 and (exists(select 1 from public.property_message_recipients r where r.message_id=m.id and r.recipient_key=actor)
   or actor=case when m.sender_type='owner' then 'owner:'||m.sender_owner_id when m.sender_type='staff' then 'employee:'||m.sender_employee_id end);
 if seen_id is null then raise exception '확인한 알림을 찾을 수 없습니다.';end if;
 update public.property_message_recipients r set read_at=clock_timestamp()
 from public.property_messages m where m.id=r.message_id and r.recipient_key=actor and r.read_at is null
 and (m.created_at,m.id)<=(seen_at,seen_id)
 and (coalesce(cardinality(p_property_ids),0)=0 or m.property_id=any(p_property_ids))
 and (m.sender_type='system' or m.message_type in('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]');
 get diagnostics changed_count=row_count;
 return jsonb_build_object('ok',true,'read_count',changed_count,'read_through_id',seen_id,'read_through_at',seen_at);
end $function$;
revoke all on function public.mark_notification_bot_seen(uuid,uuid,uuid[]) from public;
grant execute on function public.mark_notification_bot_seen(uuid,uuid,uuid[]) to anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.calendar_event_action(p_access_token uuid, p_action text, p_event jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_property_id uuid;
  v_employee_id uuid;
  v_owner boolean:=false;
  v_start timestamptz;
  v_end timestamptz;
  v_title text;
  v_details text;
  v_targets uuid[];
  v_owner_target boolean;
  v_id uuid;
  v_existing public.calendar_events%rowtype;
  v_events jsonb;
  v_tasks jsonb;
  v_employees jsonb;
begin
  select s.property_id into v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    v_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in ('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
  end if;

  if p_action='list' then
    v_start:=(p_event->>'range_start')::timestamptz;
    v_end:=(p_event->>'range_end')::timestamptz;
    if v_start is null or v_end is null or v_end<=v_start or v_end-v_start>interval '62 days' then
      return jsonb_build_object('ok',false,'message','조회 기간을 확인해주세요.');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'title',c.title,'details',c.details,'start_at',c.start_at,'end_at',c.end_at,
      'all_day',c.all_day,'owner_target',c.owner_target,
      'target_employee_ids',c.target_employee_ids,'creator_kind',c.creator_kind,
      'holiday_request_id',c.holiday_request_id,'can_edit',c.holiday_request_id is null and (v_owner or (c.creator_kind='staff' and c.creator_employee_id=v_employee_id)),
      'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name)
        from public.employees e where e.id=any(c.target_employee_ids)),'[]'::jsonb)
    ) order by c.start_at,c.created_at),'[]'::jsonb) into v_events
    from public.calendar_events c
    where c.property_id=v_property_id and c.start_at<v_end and c.end_at>v_start
      and (v_owner or v_employee_id=any(c.target_employee_ids) or (c.creator_employee_id=v_employee_id and c.holiday_request_id is null));

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',m.id,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids
    ) order by m.due_at,m.created_at),'[]'::jsonb) into v_tasks
    from public.missions m
    where m.property_id=v_property_id and m.active and m.creator_type='owner'
      and m.due_at>=v_start and m.due_at<v_end
      and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text)
      and (v_owner or (m.owner_completed_at is null and not exists(
        select 1 from public.mission_completions mc where mc.mission_id=m.id
          and (m.completion_mode='any' or mc.employee_id=v_employee_id))));
    if v_owner then
      select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name)
        order by e.display_name,e.id),'[]'::jsonb) into v_employees
      from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
    else v_employees:='[]'::jsonb;
    end if;
    return jsonb_build_object('ok',true,'events',v_events,'tasks',v_tasks,'employees',v_employees,'is_owner',v_owner);
  end if;

  if p_action='save' then
    v_title:=btrim(coalesce(p_event->>'title',''));
    v_details:=coalesce(p_event->>'details','');
    v_start:=(p_event->>'start_at')::timestamptz;
    v_end:=(p_event->>'end_at')::timestamptz;
    if char_length(v_title) not between 1 and 120 or char_length(v_details)>2000
      or v_start is null or v_end is null or v_end<=v_start or v_end-v_start>interval '7 days' then
      return jsonb_build_object('ok',false,'message','일정 제목과 시간을 확인해주세요.');
    end if;
    if v_owner then
      v_owner_target:=coalesce((p_event->>'owner_target')::boolean,false);
      select coalesce(array_agg(distinct x2.id),'{}'::uuid[]) into v_targets
      from jsonb_array_elements_text(coalesce(p_event->'target_employee_ids','[]'::jsonb)) as x(value)
      cross join lateral (select x.value::uuid as id) x2
      where x2.id is not null;
      if exists(select 1 from unnest(v_targets) t(id) where not exists(
        select 1 from public.employees e where e.id=t.id and e.property_id=v_property_id and e.active and e.role<>'owner'
      )) then return jsonb_build_object('ok',false,'message','선택한 직원 정보를 확인해주세요.'); end if;
      if not v_owner_target and cardinality(v_targets)=0 then
        return jsonb_build_object('ok',false,'message','일정 대상을 한 명 이상 선택해주세요.');
      end if;
    else
      v_owner_target:=false;
      v_targets:=array[v_employee_id];
    end if;
    if nullif(p_event->>'id','') is not null then
      v_id:=(p_event->>'id')::uuid;
      select * into v_existing from public.calendar_events c where c.id=v_id and c.property_id=v_property_id for update;
      if not found then return jsonb_build_object('ok',false,'message','일정을 찾지 못했습니다.'); end if;
    if v_existing.holiday_request_id is not null then return jsonb_build_object('ok',false,'message','휴일 신청은 결재함에서 처리해주세요.');end if;
      if not v_owner and (v_existing.creator_kind<>'staff' or v_existing.creator_employee_id is distinct from v_employee_id) then
        return jsonb_build_object('ok',false,'message','수정 권한이 없습니다.');
      end if;
      update public.calendar_events set title=v_title,details=v_details,start_at=v_start,end_at=v_end,
        all_day=coalesce((p_event->>'all_day')::boolean,false),
        owner_target=v_owner_target,target_employee_ids=v_targets,updated_at=clock_timestamp()
      where id=v_id;
    else
      insert into public.calendar_events(property_id,creator_kind,creator_employee_id,owner_target,
        target_employee_ids,title,details,start_at,end_at,all_day)
      values(v_property_id,case when v_owner then 'owner' else 'staff' end,
        case when v_owner then null else v_employee_id end,v_owner_target,v_targets,
        v_title,v_details,v_start,v_end,coalesce((p_event->>'all_day')::boolean,false))
      returning id into v_id;
    end if;
    return jsonb_build_object('ok',true,'id',v_id);
  end if;

  if p_action='delete' then
    v_id:=(p_event->>'id')::uuid;
    select * into v_existing from public.calendar_events c where c.id=v_id and c.property_id=v_property_id for update;
    if not found then return jsonb_build_object('ok',false,'message','일정을 찾지 못했습니다.'); end if;
    if v_existing.holiday_request_id is not null then return jsonb_build_object('ok',false,'message','휴일 신청은 결재함에서 처리해주세요.');end if;
    if not v_owner and (v_existing.creator_kind<>'staff' or v_existing.creator_employee_id is distinct from v_employee_id) then
      return jsonb_build_object('ok',false,'message','삭제 권한이 없습니다.');
    end if;
    delete from public.calendar_events where id=v_id;
    return jsonb_build_object('ok',true);
  end if;
  return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.list_overdue_calendar_tasks(p_access_token uuid, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_employee_id uuid;v_owner boolean:=false;v_properties uuid[];v_tasks jsonb;
begin
 select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if found then v_owner:=true;
 else
  select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 end if;
 if v_owner then
  v_properties:=coalesce(nullif(p_property_ids,array[]::uuid[]),array[v_property_id]);
  if cardinality(v_properties)>20 or exists(select 1 from unnest(v_properties) requested(id) where requested.id<>v_property_id and not omg_private.can_manage_shared_property(p_access_token,requested.id,'missions')) then
   return jsonb_build_object('ok',false,'message','숙소 권한을 확인해주세요.');
  end if;
 else v_properties:=array[v_property_id];
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids) order by m.due_at,m.created_at),'[]'::jsonb)
 into v_tasks
 from public.missions m join public.properties p on p.id=m.property_id
 where m.property_id=any(v_properties) and m.active and m.owner_completed_at is null and m.creator_type='owner' and m.due_at<clock_timestamp()
  and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text)
  and (v_owner or (m.owner_completed_at is null and not exists(
        select 1 from public.mission_completions mc where mc.mission_id=m.id
          and (m.completion_mode='any' or mc.employee_id=v_employee_id))));
 return jsonb_build_object('ok',true,'tasks',v_tasks);
end$function$
;
commit;
