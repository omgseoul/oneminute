-- Staff attendance correction requests and owner approval workflow.
begin;

create table if not exists public.attendance_adjustment_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  employee_id uuid not null,
  work_session_id uuid not null,
  original_clock_in_at timestamptz not null,
  original_clock_out_at timestamptz,
  requested_clock_in_at timestamptz not null,
  requested_clock_out_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending','approved')),
  requested_at timestamptz not null default clock_timestamp(),
  approved_at timestamptz,
  approved_by uuid references public.owners(id),
  foreign key (work_session_id,business_id,property_id,employee_id)
    references public.work_sessions(id,business_id,property_id,employee_id),
  unique (work_session_id)
);

create index if not exists attendance_adjustment_property_status_idx
  on public.attendance_adjustment_requests(property_id,status,requested_at desc);

alter table public.attendance_adjustment_requests enable row level security;
revoke all on table public.attendance_adjustment_requests from public,anon,authenticated;

alter table public.urgent_messages
  add column if not exists message_type text not null default 'urgent'
    check (message_type in ('urgent','attendance_approval')),
  add column if not exists attendance_request_id uuid
    references public.attendance_adjustment_requests(id);

create or replace function public.request_attendance_adjustment(
  p_access_token uuid,
  p_work_session_id uuid,
  p_clock_in_time time,
  p_clock_out_time time
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_login public.work_sessions%rowtype;
  v_target public.work_sessions%rowtype;
  v_employee_name text;
  v_timezone text;
  v_requested_clock_in_at timestamptz;
  v_requested_clock_out_at timestamptz;
  v_request_id uuid;
  v_message text;
begin
  select s.* into v_login
  from public.work_sessions s
  join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then
    return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 수정 요청할 수 있습니다.');
  end if;

  select s.* into v_target from public.work_sessions s
  where s.id=p_work_session_id and s.property_id=v_login.property_id
    and s.employee_id=v_login.employee_id for update;
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','message','수정할 근무 기록을 찾을 수 없습니다.');
  end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_target.property_id;
  v_requested_clock_in_at := (v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_requested_clock_out_at := (v_target.work_date+p_clock_out_time
    + case when p_clock_out_time<=p_clock_in_time then interval '1 day' else interval '0' end) at time zone v_timezone;
  if p_clock_in_time is null or p_clock_out_time is null
     or v_requested_clock_out_at-v_requested_clock_in_at>interval '24 hours' then
    return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.');
  end if;
  if exists(select 1 from public.attendance_adjustment_requests r where r.work_session_id=v_target.id) then
    return jsonb_build_object('ok',false,'code','already_requested','message','이미 제출된 수정 요청이 있습니다.');
  end if;

  insert into public.attendance_adjustment_requests(
    business_id,property_id,employee_id,work_session_id,
    original_clock_in_at,original_clock_out_at,
    requested_clock_in_at,requested_clock_out_at
  ) values(
    v_target.business_id,v_target.property_id,v_target.employee_id,v_target.id,
    v_target.clock_in_at,v_target.clock_out_at,v_requested_clock_in_at,v_requested_clock_out_at
  ) returning id into v_request_id;

  select e.display_name into v_employee_name from public.employees e where e.id=v_target.employee_id;
  v_message := format(
    '출퇴근 시간 수정 요청\n근무일: %s\n기존: %s ~ %s\n요청: %s ~ %s',
    v_target.work_date,
    to_char(v_target.clock_in_at at time zone 'Asia/Seoul','HH24:MI'),
    coalesce(to_char(v_target.clock_out_at at time zone 'Asia/Seoul','HH24:MI'),'-'),
    to_char(v_requested_clock_in_at at time zone v_timezone,'HH24:MI'),
    to_char(v_requested_clock_out_at at time zone v_timezone,'HH24:MI')
  );
  insert into public.urgent_messages(
    business_id,property_id,employee_id,message,message_type,attendance_request_id
  ) values(
    v_target.business_id,v_target.property_id,v_target.employee_id,v_message,'attendance_approval',v_request_id
  );

  return jsonb_build_object('ok',true,'request_id',v_request_id,'status','pending','employee_name',v_employee_name);
end;
$$;

create or replace function public.approve_attendance_adjustment(
  p_access_token uuid,
  p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_property_id uuid;
  v_owner_id uuid;
  v_request public.attendance_adjustment_requests%rowtype;
begin
  select s.property_id,s.owner_id into v_property_id,v_owner_id
  from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 결재할 수 있습니다.');
  end if;

  select * into v_request from public.attendance_adjustment_requests
  where id=p_request_id and property_id=v_property_id for update;
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','message','수정 요청을 찾을 수 없습니다.');
  end if;
  if v_request.status='approved' then
    return jsonb_build_object('ok',true,'status','approved','already_approved',true);
  end if;

  update public.work_sessions set
    clock_in_at=v_request.requested_clock_in_at,
    clock_out_at=v_request.requested_clock_out_at,
    status='completed'
  where id=v_request.work_session_id and property_id=v_property_id;

  update public.attendance_adjustment_requests set
    status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id
  where id=v_request.id;

  update public.urgent_messages set
    acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_by=coalesce(acknowledged_by,v_owner_id)
  where attendance_request_id=v_request.id and property_id=v_property_id;

  return jsonb_build_object('ok',true,'status','approved');
end;
$$;

create or replace function public.list_attendance_statistics(
  p_access_token uuid,
  p_from_date date,
  p_to_date date
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_property_id uuid;
  v_employee_id uuid;
  v_timezone text;
  v_is_owner boolean:=false;
  v_sessions jsonb:='[]'::jsonb;
  v_employees jsonb:='[]'::jsonb;
begin
  select s.property_id,p.timezone into v_property_id,v_timezone
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  join public.properties p on p.id=s.property_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id,p.timezone into v_property_id,v_employee_id,v_timezone
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    join public.properties p on p.id=s.property_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
  end if;
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'code','invalid_period','message','조회 기간을 확인해주세요.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id',s.id,'employee_id',s.employee_id,'employee_name',e.display_name,
    'work_date',s.work_date,'clock_in_at',s.clock_in_at,'clock_out_at',s.clock_out_at,
    'duration_minutes',case when s.clock_out_at is null then null else greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)::integer) end,
    'status',s.status,'checkin_report_at',s.checkin_report_at,'checkout_report_at',s.checkout_report_at,
    'adjustment_request_id',r.id,'adjustment_status',r.status,
    'requested_clock_in_at',r.requested_clock_in_at,'requested_clock_out_at',r.requested_clock_out_at
  ) order by s.work_date desc,s.clock_in_at desc),'[]'::jsonb)
  into v_sessions
  from public.work_sessions s join public.employees e on e.id=s.employee_id
  left join public.attendance_adjustment_requests r on r.work_session_id=s.id
  where s.property_id=v_property_id and s.work_date between p_from_date and p_to_date
    and(v_is_owner or s.employee_id=v_employee_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',e.id,'display_name',e.display_name,'active',e.active
  ) order by e.active desc,e.created_at,e.id),'[]'::jsonb) into v_employees
  from public.employees e where e.property_id=v_property_id and e.role<>'owner'
    and(v_is_owner or e.id=v_employee_id)
    and(e.active or exists(select 1 from public.work_sessions s where s.employee_id=e.id and s.work_date between p_from_date and p_to_date));

  return jsonb_build_object('ok',true,'scope',case when v_is_owner then 'property' else 'self' end,
    'timezone',v_timezone,'from_date',p_from_date,'to_date',p_to_date,
    'employees',v_employees,'sessions',v_sessions);
end;
$$;

create or replace function public.list_urgent_messages(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_items jsonb;v_unread integer;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 받은 메시지를 확인할 수 있습니다.'); end if;
  select count(*)::integer into v_unread from public.urgent_messages
  where property_id=v_property_id and acknowledged_at is null;
  select coalesce(jsonb_agg(jsonb_build_object(
    'message_id',m.id,'employee_id',m.employee_id,'employee_name',e.display_name,
    'message',m.message,'message_type',m.message_type,'attendance_request_id',m.attendance_request_id,
    'approval_status',r.status,'requested_clock_in_at',r.requested_clock_in_at,
    'requested_clock_out_at',r.requested_clock_out_at,
    'created_at',m.created_at,'acknowledged_at',m.acknowledged_at
  ) order by m.created_at desc),'[]'::jsonb) into v_items
  from(select * from public.urgent_messages where property_id=v_property_id order by created_at desc limit 100)m
  join public.employees e on e.id=m.employee_id
  left join public.attendance_adjustment_requests r on r.id=m.attendance_request_id;
  return jsonb_build_object('ok',true,'messages',v_items,'unread_count',v_unread);
end;
$$;

revoke all on function public.request_attendance_adjustment(uuid,uuid,time,time),public.approve_attendance_adjustment(uuid,uuid) from public;
grant execute on function public.request_attendance_adjustment(uuid,uuid,time,time),public.approve_attendance_adjustment(uuid,uuid) to anon,authenticated;

commit;
select '출퇴근 수정 요청·관리자 결재 준비 완료' as result;
