-- Administrator IDs are entered directly, scoped to the signed-in account's property.
create or replace function public.start_account_admin_session_by_login(p_login_id text,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
 select o.id into target from public.account_properties a join public.owners o on o.property_id=a.property_id
 where a.user_id=auth.uid() and o.active and lower(o.login_id)=lower(btrim(p_login_id));
 if target is null then return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자 아이디와 PIN을 확인해주세요.');end if;
 return public.start_account_admin_session(target,p_pin);
end $$;
revoke all on function public.start_account_admin_session_by_login(text,text) from public,anon;
grant execute on function public.start_account_admin_session_by_login(text,text) to authenticated;
-- Convert only the unchanged legacy default; custom IDs and PINs remain intact.
update public.owners o set login_id='admin' where o.active and o.login_id='관리자' and o.display_name='관리자'
 and not exists(select 1 from public.owners x where x.business_id=o.business_id and x.active and lower(x.login_id)='admin');

create or replace function omg_private.target_work_state(p_employee uuid) returns text language sql stable set search_path='' as $$
 select coalesce((select case when s.status='working' and s.clock_out_at is null then
   case when s.checkin_report_at is not null then 'working' else 'waiting' end else 'off' end
 from public.work_sessions s where s.employee_id=p_employee order by s.created_at desc,s.id desc limit 1),'off')
$$;
revoke all on function omg_private.target_work_state(uuid) from public,anon,authenticated;

create or replace function public.list_target_people(p_access_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare own uuid;props jsonb;people jsonb;
begin
 select s.property_id into own from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if own is null then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 로그인이 필요합니다.');end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'management_number',p.management_number)
 order by (p.id=own) desc,p.management_number,p.name),'[]') into props from public.properties p
 where omg_private.can_manage_shared_property(p_access_token,p.id,'missions');
 select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'name',e.display_name,'property_id',p.id,'property_name',p.name,
 'profile_image',e.profile_image,'work_state',omg_private.target_work_state(e.id)) order by (p.id=own) desc,p.management_number,e.display_name),'[]') into people
 from public.employees e join public.properties p on p.id=e.property_id where e.active and e.role<>'owner'
 and omg_private.can_manage_shared_property(p_access_token,p.id,'missions');
 return jsonb_build_object('ok',true,'properties',props,'people',people);
end $$;
revoke all on function public.list_target_people(uuid) from public;
grant execute on function public.list_target_people(uuid) to anon,authenticated;


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
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',case when m.source='work_confirmation' then 'work_confirmation' else m.message_type end,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
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

CREATE OR REPLACE FUNCTION public.save_mission(p_access_token uuid, p_mission jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_business_id uuid;v_property_id uuid;v_employee_id uuid;v_id uuid;v_targets jsonb;v_due timestamptz;
  v_mode text;v_is_owner boolean:=false;v_priority text;v_description_photo text:=coalesce(p_mission->>'description_photo','');
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
    if nullif(p_mission->>'id','') is not null then
      select m.business_id,m.property_id into v_business_id,v_property_id from public.missions m
      where m.id=(p_mission->>'id')::uuid and m.active
        and omg_private.can_manage_shared_property(p_access_token,m.property_id,'missions') for update;
      if not found then return jsonb_build_object('ok',false,'code','forbidden','message','이 할 일을 수정할 권한이 없습니다.');end if;
    end if;
  else
    select s.business_id,s.property_id,s.employee_id into v_business_id,v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  if v_is_owner and nullif(p_mission->>'id','') is null and nullif(p_mission->>'property_id','') is not null then
    v_property_id:=(p_mission->>'property_id')::uuid;
    if not omg_private.can_manage_shared_property(p_access_token,v_property_id,'missions') then
      return jsonb_build_object('ok',false,'code','forbidden','message','선택한 지점에 업무를 등록할 권한이 없습니다.');end if;
    select business_id into v_business_id from public.properties where id=v_property_id;
  end if;
  v_priority:=case when coalesce(p_mission->>'priority','normal') in('important','urgent') then 'important' else 'normal' end;
  if jsonb_typeof(p_mission)<>'object' or char_length(btrim(coalesce(p_mission->>'title',''))) not between 1 and 100
    or char_length(coalesce(p_mission->>'description',''))>2000 or octet_length(v_description_photo)>30000000
    or (v_description_photo<>'' and v_description_photo not like 'data:image/%' and v_description_photo not like 'data:video/webm;base64,%')
    or coalesce(p_mission->>'timing','') not in('today','this_week','anytime') then
    return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용과 첨부 파일을 확인해주세요.');
  end if;
  if v_is_owner then v_targets:=coalesce(p_mission->'target_employee_ids','[]'::jsonb);
  else
    if nullif(p_mission->>'id','') is not null then return jsonb_build_object('ok',false,'code','owner_required','message','직원은 새 미션만 등록할 수 있습니다.'); end if;
    v_targets:=jsonb_build_array(v_employee_id);
  end if;
  if jsonb_typeof(v_targets)<>'array' or jsonb_array_length(v_targets)>50
    or exists(select 1 from jsonb_array_elements_text(v_targets)x(value)
      where not exists(select 1 from public.employees e where e.id::text=x.value and e.property_id=v_property_id and e.active)) then
    return jsonb_build_object('ok',false,'code','invalid_target','message','담당 근무자를 확인해주세요.');
  end if;
  v_mode:=coalesce(p_mission->>'completion_mode','all');
  if v_mode not in ('all','any') or (v_mode='any' and (not v_is_owner or jsonb_array_length(v_targets)<>0)) then
    return jsonb_build_object('ok',false,'code','invalid_completion_mode','message','완료 방식을 확인해주세요.');
  end if;
  begin v_due:=nullif(p_mission->>'due_at','')::timestamptz;
  exception when others then return jsonb_build_object('ok',false,'code','invalid_due_at','message','마감일시를 확인해주세요.'); end;
  begin v_id:=nullif(p_mission->>'id','')::uuid;
  exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션을 확인해주세요.'); end;
  if v_id is null then
    insert into public.missions(business_id,property_id,title,description,description_photo,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at,creator_type,creator_employee_id,completion_mode)
    values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),v_description_photo,p_mission->>'timing',v_priority,
      v_targets,coalesce((p_mission->>'photo_required')::boolean,false),30,v_due,case when v_is_owner then 'owner' else 'staff' end,v_employee_id,v_mode)
    returning id into v_id;
  else
    update public.missions set title=btrim(p_mission->>'title'),description=coalesce(p_mission->>'description',''),description_photo=v_description_photo,
      completion_mode=v_mode,timing=p_mission->>'timing',priority=v_priority,target_employee_ids=v_targets,
      photo_required=coalesce((p_mission->>'photo_required')::boolean,false),due_at=v_due,updated_at=clock_timestamp()
    where id=v_id and property_id=v_property_id and active and v_is_owner;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  end if;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end;
$function$

;

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

  if v_owner and p_action in ('save','delete') then
    if nullif(p_event->>'id','') is not null then
      select c.property_id into v_property_id from public.calendar_events c where c.id=(p_event->>'id')::uuid;
    elsif nullif(p_event->>'property_id','') is not null then v_property_id:=(p_event->>'property_id')::uuid;end if;
    if v_property_id is null or not omg_private.can_manage_shared_property(p_access_token,v_property_id,'missions') then
      return jsonb_build_object('ok',false,'message','선택한 일정의 지점 권한을 확인해주세요.');end if;
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

CREATE OR REPLACE FUNCTION public.list_shared_calendar_board(p_access_token uuid, p_property_ids uuid[], p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_own uuid;v_events jsonb;v_tasks jsonb;
BEGIN
 SELECT s.property_id INTO v_own FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_access_token) AND s.token_expires_at>clock_timestamp() AND o.active;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'message','관리자 로그인 후 이용해주세요.'); END IF;
 IF cardinality(p_property_ids) NOT BETWEEN 1 AND 20 OR p_from IS NULL OR p_to<=p_from OR p_to-p_from>interval '62 days'
    OR EXISTS(SELECT 1 FROM unnest(p_property_ids) id WHERE NOT omg_private.can_manage_shared_property(p_access_token,id,'missions')) THEN
   RETURN jsonb_build_object('ok',false,'message','조회 기간 또는 숙소 권한을 확인해주세요.');
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'property_id',c.property_id,'property_name',p.name,'title',c.title,'details',c.details,'start_at',c.start_at,'end_at',c.end_at,
   'all_day',c.all_day,'owner_target',c.owner_target,'target_employee_ids',c.target_employee_ids,
   'creator_kind',c.creator_kind,'holiday_request_id',c.holiday_request_id,
   'can_edit',c.holiday_request_id IS NULL,
   'target_names',coalesce((SELECT jsonb_agg(e.display_name ORDER BY e.display_name) FROM public.employees e WHERE e.id=any(c.target_employee_ids)),'[]'::jsonb)
 ) ORDER BY c.start_at,c.created_at),'[]'::jsonb) INTO v_events
 FROM public.calendar_events c JOIN public.properties p ON p.id=c.property_id
 WHERE c.property_id=any(p_property_ids) AND c.start_at<p_to AND c.end_at>p_from;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,
   'target_employee_ids',m.target_employee_ids) ORDER BY m.due_at,m.created_at),'[]'::jsonb) INTO v_tasks
 FROM public.missions m JOIN public.properties p ON p.id=m.property_id
 WHERE m.property_id=any(p_property_ids) AND m.active AND m.owner_completed_at IS NULL AND m.creator_type='owner' AND m.due_at>=p_from AND m.due_at<p_to;
 RETURN jsonb_build_object('ok',true,'events',v_events,'tasks',v_tasks);
END $function$

;

-- One atomic operation creates per-branch targets, preserving independent completion rules.
create or replace function public.save_targeted_tasks(p_access_token uuid,p_kind text,p_item jsonb,p_targets jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare part jsonb;result jsonb;ids jsonb:='[]';payload jsonb;
begin
 if p_kind is null or p_kind not in ('mission','calendar') or jsonb_typeof(p_targets) is distinct from 'array' or jsonb_array_length(p_targets) not between 1 and 20 then
   return jsonb_build_object('ok',false,'message','대상을 한 명 이상 선택해주세요.');end if;
 if nullif(p_item->>'id','') is not null and jsonb_array_length(p_targets)<>1 then return jsonb_build_object('ok',false,'message','기존 항목은 해당 지점 안에서 대상을 변경해주세요.');end if;
 if (select count(distinct x->>'property_id') from jsonb_array_elements(p_targets)x)<>jsonb_array_length(p_targets) then return jsonb_build_object('ok',false,'message','중복된 지점입니다.');end if;
 for part in select value from jsonb_array_elements(p_targets) loop
   if not omg_private.can_manage_shared_property(p_access_token,(part->>'property_id')::uuid,'missions') then raise exception '대상 지점의 권한이 없습니다.';end if;
   if nullif(p_item->>'id','') is not null and ((p_kind='mission' and not exists(select 1 from public.missions where id=(p_item->>'id')::uuid and property_id=(part->>'property_id')::uuid))
     or(p_kind='calendar' and not exists(select 1 from public.calendar_events where id=(p_item->>'id')::uuid and property_id=(part->>'property_id')::uuid))) then raise exception '기존 항목의 지점을 변경할 수 없습니다.';end if;
   payload:=p_item||jsonb_build_object('property_id',part->>'property_id','target_employee_ids',coalesce(part->'target_employee_ids','[]'::jsonb),'completion_mode',coalesce(part->>'completion_mode','all'),'owner_target',coalesce((part->>'owner_target')::boolean,false));
   if p_kind='mission' then result:=public.save_mission(p_access_token,payload);else result:=public.calendar_event_action(p_access_token,'save',payload);end if;
   if coalesce((result->>'ok')::boolean,false) is not true then raise exception '%',coalesce(result->>'message','저장하지 못했습니다.');end if;
   ids:=ids||jsonb_build_array(coalesce(result->>'mission_id',result->>'id'));
 end loop;
 return jsonb_build_object('ok',true,'ids',ids);
exception when others then return jsonb_build_object('ok',false,'message',sqlerrm);
end $$;
revoke all on function public.save_targeted_tasks(uuid,text,jsonb,jsonb) from public;
grant execute on function public.save_targeted_tasks(uuid,text,jsonb,jsonb) to anon,authenticated;
