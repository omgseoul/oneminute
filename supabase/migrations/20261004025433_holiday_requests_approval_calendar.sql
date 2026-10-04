-- Holiday requests use the application's existing hashed owner/staff sessions.
create table public.holiday_request_settings (
  property_id uuid primary key references public.properties(id) on delete cascade,
  notice_enabled boolean not null default true,
  notice_text text not null default '휴일 신청은 관리자 결재 후 확정됩니다.' check(char_length(notice_text)<=4000),
  acknowledgement_required boolean not null default true,
  acknowledgement_label text not null default '이해했음' check(char_length(acknowledgement_label) between 1 and 100),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.holiday_request_settings enable row level security;
revoke all on public.holiday_request_settings from public,anon,authenticated;

create table public.holiday_requests (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  requester_employee_id uuid not null references public.employees(id),
  target_employee_ids uuid[] not null check(cardinality(target_employee_ids)>0),
  holiday_date date not null,
  reason text not null check(char_length(btrim(reason)) between 1 and 1500),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  notice_snapshot text not null default '',
  acknowledgement_label text,
  acknowledged_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  decided_at timestamptz,
  decided_by uuid references public.owners(id)
);
create index holiday_requests_property_date_idx on public.holiday_requests(property_id,holiday_date);
create index holiday_requests_requester_idx on public.holiday_requests(requester_employee_id);
create index holiday_requests_decided_by_idx on public.holiday_requests(decided_by);
alter table public.holiday_requests enable row level security;
revoke all on public.holiday_requests from public,anon,authenticated;
alter table public.property_messages add column holiday_request_id uuid references public.holiday_requests(id);
create index property_messages_holiday_request_idx on public.property_messages(holiday_request_id) where holiday_request_id is not null;
alter table public.property_messages drop constraint property_messages_message_type_check;
alter table public.property_messages add constraint property_messages_message_type_check check(message_type in ('general','emergency_report','attendance_approval','property_share_approval','announcement','attendance_warning','holiday_approval','holiday_notice'));
alter table public.calendar_events add column holiday_request_id uuid unique references public.holiday_requests(id);

create or replace function public.holiday_request_action(p_access_token uuid,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_property uuid;v_business uuid;v_employee uuid;v_owner uuid;v_timezone text;
  v_settings public.holiday_request_settings%rowtype;
  v_request public.holiday_requests%rowtype;
  v_targets uuid[];v_date date;v_reason text;v_id uuid;v_message uuid;v_notice uuid;
  v_names text;v_requester text;v_body text;v_status text;v_label text;
begin
  select s.property_id,s.business_id,s.owner_id into v_property,v_business,v_owner
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.property_id,s.business_id,s.employee_id into v_property,v_business,v_employee
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in ('working','completed');
    if not found then return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
  end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_property;
  select * into v_settings from public.holiday_request_settings where property_id=v_property;
  if not found then
    v_settings.property_id:=v_property;v_settings.notice_enabled:=true;
    v_settings.notice_text:='휴일 신청은 관리자 결재 후 확정됩니다.';
    v_settings.acknowledgement_required:=true;v_settings.acknowledgement_label:='이해했음';
  end if;
  if p_action in ('settings_get','settings_save') then
    if v_owner is null then return jsonb_build_object('ok',false,'message','관리자만 설정할 수 있습니다.');end if;
    if p_action='settings_save' then
      v_settings.notice_enabled:=coalesce((p_data->>'notice_enabled')::boolean,false);
      v_settings.notice_text:=btrim(coalesce(p_data->>'notice_text',''));
      v_settings.acknowledgement_required:=coalesce((p_data->>'acknowledgement_required')::boolean,true);
      v_settings.acknowledgement_label:=btrim(coalesce(p_data->>'acknowledgement_label','이해했음'));
      if char_length(v_settings.notice_text)>4000 or (v_settings.notice_enabled and v_settings.notice_text='')
        or char_length(v_settings.acknowledgement_label) not between 1 and 100 then
        return jsonb_build_object('ok',false,'message','공지 내용과 이해 확인 문구를 확인해주세요.');end if;
      insert into public.holiday_request_settings(property_id,notice_enabled,notice_text,acknowledgement_required,acknowledgement_label)
      values(v_property,v_settings.notice_enabled,v_settings.notice_text,v_settings.acknowledgement_required,v_settings.acknowledgement_label)
      on conflict(property_id) do update set notice_enabled=excluded.notice_enabled,notice_text=excluded.notice_text,
        acknowledgement_required=excluded.acknowledgement_required,acknowledgement_label=excluded.acknowledgement_label,updated_at=clock_timestamp()
      returning * into v_settings;
    end if;
    return jsonb_build_object('ok',true,'settings',to_jsonb(v_settings));
  end if;
  if p_action='context' then
    if v_employee is null then return jsonb_build_object('ok',false,'message','근무자 로그인 후 신청해주세요.');end if;
    return jsonb_build_object('ok',true,'employee_id',v_employee,'today',(clock_timestamp() at time zone v_timezone)::date,
      'settings',to_jsonb(v_settings),'employees',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name) order by e.display_name),'[]'::jsonb)
      from public.employees e where e.property_id=v_property and e.active and e.role<>'owner'));
  end if;
  if p_action='submit' then
    if v_employee is null then return jsonb_build_object('ok',false,'message','근무자 로그인 후 신청해주세요.');end if;
    v_id:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());
    select * into v_request from public.holiday_requests where id=v_id;
    if found then
      if v_request.requester_employee_id<>v_employee or v_request.property_id<>v_property then
        return jsonb_build_object('ok',false,'message','신청 정보를 확인해주세요.');end if;
      return jsonb_build_object('ok',true,'id',v_id,'status',v_request.status,'message_id',
        (select id from public.property_messages where holiday_request_id=v_id and message_type='holiday_approval' limit 1));
    end if;
    v_date:=(p_data->>'holiday_date')::date;v_reason:=btrim(coalesce(p_data->>'reason',''));
    select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_targets
      from jsonb_array_elements_text(coalesce(p_data->'target_employee_ids','[]'::jsonb));
    if v_date is null or char_length(v_reason) not between 1 and 1500 or cardinality(v_targets)=0
      or exists(select 1 from unnest(v_targets) t(id) where not exists(select 1 from public.employees e where e.id=t.id and e.property_id=v_property and e.active and e.role<>'owner')) then
      return jsonb_build_object('ok',false,'message','날짜, 대상, 휴일 신청 사유를 확인해주세요.');end if;
    if v_settings.notice_enabled then
      if not coalesce((p_data->>'notice_seen')::boolean,false)
        or (v_settings.acknowledgement_required and not coalesce((p_data->>'acknowledged')::boolean,false)) then
        return jsonb_build_object('ok',false,'message','휴일 신청 안내를 먼저 확인해주세요.');end if;
      if v_settings.updated_at is distinct from (p_data->>'notice_version')::timestamptz then
        return jsonb_build_object('ok',false,'message','안내 내용이 변경되었습니다. 신청창을 다시 열어 확인해주세요.');end if;
    end if;
    perform pg_advisory_xact_lock(hashtextextended(v_property::text||v_date::text,0));
    if exists(select 1 from public.holiday_requests r where r.property_id=v_property and r.holiday_date=v_date and r.status<>'rejected' and r.target_employee_ids && v_targets) then
      return jsonb_build_object('ok',false,'message','선택한 대상 중 해당 날짜에 이미 휴일을 신청한 근무자가 있습니다.');end if;
    if not exists(select 1 from public.owners o where o.property_id=v_property and o.active) then
      return jsonb_build_object('ok',false,'message','결재할 관리자를 찾지 못했습니다. 관리자에게 문의해주세요.');end if;
    select string_agg(e.display_name,', ' order by e.display_name) into v_names from public.employees e where e.id=any(v_targets);
    select display_name into v_requester from public.employees where id=v_employee;
    v_body:=format(E'미결재 - 휴일신청\n날짜: %s\n신청자: %s\n대상: %s\n휴일 신청 사유: %s',v_date,v_requester,v_names,v_reason);
    if char_length(v_body)>1999 then return jsonb_build_object('ok',false,'message','대상 또는 사유가 너무 깁니다. 내용을 줄여주세요.');end if;
    insert into public.holiday_requests(id,property_id,requester_employee_id,target_employee_ids,holiday_date,reason,notice_snapshot,acknowledgement_label,acknowledged_at)
    values(v_id,v_property,v_employee,v_targets,v_date,v_reason,case when v_settings.notice_enabled then v_settings.notice_text else '' end,
      case when v_settings.notice_enabled and v_settings.acknowledgement_required then v_settings.acknowledgement_label end,
      case when v_settings.notice_enabled and v_settings.acknowledgement_required then clock_timestamp() end);
    insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type,holiday_request_id)
      values(v_business,v_property,'staff',v_employee,v_body,'normal','holiday_approval',v_id) returning id into v_message;
    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
      select v_message,'owner:'||o.id,'owner',o.id from public.owners o where o.active and (o.property_id=v_property or exists(
        select 1 from public.property_share_requests r where r.target_property_id=v_property and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)));
    insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,holiday_request_id)
      values(v_business,v_property,'system',v_body,'normal','holiday_notice',v_id) returning id into v_notice;
    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
      select v_notice,'employee:'||e.id,'staff',e.id from public.employees e where e.id=any(v_targets||array[v_employee]);
    insert into public.calendar_events(property_id,creator_kind,creator_employee_id,target_employee_ids,title,details,start_at,end_at,all_day,holiday_request_id)
      values(v_property,'staff',v_employee,v_targets,'휴일 (미결재)',v_body,v_date::timestamp at time zone v_timezone,(v_date+1)::timestamp at time zone v_timezone,true,v_id);
    return jsonb_build_object('ok',true,'id',v_id,'status','pending','message_id',v_message);
  end if;
  if p_action in ('approve','reject') then
    if v_owner is null then return jsonb_build_object('ok',false,'message','관리자만 결재할 수 있습니다.');end if;
    select * into v_request from public.holiday_requests where id=(p_data->>'id')::uuid for update;
    if not found or not(v_request.property_id=v_property or exists(select 1 from public.property_share_requests r
      where r.requester_property_id=v_property and r.target_property_id=v_request.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))) then
      return jsonb_build_object('ok',false,'message','결재 권한이 있는 휴일 신청을 찾을 수 없습니다.');end if;
    v_status:=case when p_action='approve' then 'approved' else 'rejected' end;
    if v_request.status=v_status then return jsonb_build_object('ok',true,'status',v_status);end if;
    if v_request.status<>'pending' then return jsonb_build_object('ok',false,'message','이미 처리된 신청입니다.');end if;
    update public.holiday_requests set status=v_status,decided_at=clock_timestamp(),decided_by=v_owner where id=v_request.id;
    v_label:=case when v_status='approved' then '결재완료' else '반려' end;
    update public.property_messages set message=regexp_replace(message,'^미결재 - 휴일신청',v_label||' - 휴일신청') where holiday_request_id=v_request.id;
    update public.property_message_recipients r set read_at=case when r.recipient_type='owner' then coalesce(r.read_at,clock_timestamp()) else null end
      from public.property_messages m where m.id=r.message_id and m.holiday_request_id=v_request.id;
    if v_status='approved' then
      update public.calendar_events set title='휴일 (결재완료)',details=regexp_replace(details,'^미결재 - 휴일신청','결재완료 - 휴일신청'),updated_at=clock_timestamp() where holiday_request_id=v_request.id;
    else delete from public.calendar_events where holiday_request_id=v_request.id;end if;
    select id into v_notice from public.property_messages where holiday_request_id=v_request.id and message_type='holiday_notice';
    return jsonb_build_object('ok',true,'status',v_status,'message_id',v_notice);
  end if;
  return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');
end;$$;
revoke all on function public.holiday_request_action(uuid,text,jsonb) from public;
grant execute on function public.holiday_request_action(uuid,text,jsonb) to anon,authenticated;

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
      'property_id',p.id,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
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
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'holiday_request_id',m.holiday_request_id,'approval_status',coalesce(ar.status,psr.status,hr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.holiday_requests hr on hr.id=m.holiday_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$function$;


create or replace function public.calendar_event_action(p_access_token uuid,p_action text,p_event jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
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
      and (v_owner or c.creator_employee_id=v_employee_id or v_employee_id=any(c.target_employee_ids));

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',m.id,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids
    ) order by m.due_at,m.created_at),'[]'::jsonb) into v_tasks
    from public.missions m
    where m.property_id=v_property_id and m.active and m.creator_type='owner'
      and m.due_at>=v_start and m.due_at<v_end
      and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text);
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
$function$;
revoke all on function public.calendar_event_action(uuid,text,jsonb) from public;
grant execute on function public.calendar_event_action(uuid,text,jsonb) to anon,authenticated;


CREATE OR REPLACE FUNCTION public.get_message_push_dispatch(p_access_token uuid, p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_message public.property_messages%rowtype;v_number integer;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select * into v_message from public.property_messages m where m.id=p_message_id and (m.property_id=v_property_id or (v_owner_id is not null and m.message_type='holiday_notice' and exists(select 1 from public.holiday_requests h where h.id=m.holiday_request_id and h.decided_by=v_owner_id))) and(
    (v_owner_id is not null and (m.sender_owner_id=v_owner_id or (m.message_type='holiday_notice' and exists(select 1 from public.holiday_requests h where h.id=m.holiday_request_id and h.decided_by=v_owner_id))))or(v_employee_id is not null and m.sender_employee_id=v_employee_id)
    or(v_employee_id is not null and m.sender_type='system' and exists(select 1 from public.property_message_recipients r where r.message_id=m.id and r.employee_id=v_employee_id)));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','전송할 메세지를 찾을 수 없습니다.'); end if;
  select management_number into v_number from public.properties where id=v_message.property_id;
  return jsonb_build_object('ok',true,'management_number',v_number,'message_id',v_message.id,
    'message',case when v_message.priority='urgent' then v_message.message else '[[OMG_NORMAL_MESSAGE]]'||v_message.message end,
    'priority',v_message.priority,'message_type',v_message.message_type,
    'sender_label',case when v_message.sender_type='owner' then coalesce((select display_name from public.owners where id=v_message.sender_owner_id),'관리자')
      when v_message.sender_type='system' then '근태관리' else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb));
end;
$function$;

