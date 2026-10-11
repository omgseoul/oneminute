CREATE OR REPLACE FUNCTION public.approve_attendance_adjustment(p_access_token uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_owner_id uuid;v_request public.attendance_adjustment_requests%rowtype;
begin
  select s.property_id,s.owner_id into v_property_id,v_owner_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 결재할 수 있습니다.'); end if;
  select * into v_request from public.attendance_adjustment_requests where id=p_request_id for update;
  if not found or not(v_request.property_id=v_property_id or exists(select 1 from public.property_share_requests r
    where r.requester_property_id=v_property_id and r.target_property_id=v_request.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','not_found','message','결재 권한이 있는 수정 요청을 찾을 수 없습니다.'); end if;
  if v_request.status='approved' then return jsonb_build_object('ok',true,'status','approved','already_approved',true); end if;
  if v_request.status<>'pending' then return jsonb_build_object('ok',false,'code','already_decided','message','반려된 요청입니다. 새 수정 요청을 확인해주세요.'); end if;
  if v_request.requested_clock_in_at>clock_timestamp() or v_request.requested_clock_out_at>clock_timestamp() then return jsonb_build_object('ok',false,'code','future_time','message','현재 시각 이후의 출근·퇴근시간은 승인할 수 없습니다. 시간을 다시 수정해주세요.'); end if;
  update public.work_sessions set clock_in_at=v_request.requested_clock_in_at,clock_out_at=v_request.requested_clock_out_at,status='completed' where id=v_request.work_session_id and property_id=v_request.property_id;
  update public.attendance_adjustment_requests set status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp()) from public.property_messages m
    where r.message_id=m.id and m.attendance_request_id=v_request.id and r.recipient_type='owner';
  return jsonb_build_object('ok',true,'status','approved');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.owner_update_attendance(p_access_token uuid, p_work_session_id uuid, p_clock_in_time time without time zone, p_clock_out_time time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_owner_session public.owner_sessions%rowtype;
  v_target public.work_sessions%rowtype;
  v_timezone text;
  v_clock_in_at timestamptz;
  v_clock_out_at timestamptz;
begin
  select s.* into v_owner_session
  from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp()
    and o.active;
  if not found then
    return jsonb_build_object('ok',false,'code','owner_required','message','관리자 로그인 후 수정할 수 있습니다.');
  end if;

  select s.* into v_target
  from public.work_sessions s
  where s.id=p_work_session_id
    and s.property_id=v_owner_session.property_id
  for update;
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','message','자기 지점의 근무 기록만 수정할 수 있습니다.');
  end if;
  if p_clock_in_time is null or p_clock_out_time is null then
    return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 모두 입력해주세요.');
  end if;

  select p.timezone into v_timezone
  from public.properties p where p.id=v_target.property_id;
  v_clock_in_at := (v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_clock_out_at := (v_target.work_date+p_clock_out_time
    + case when p_clock_out_time<=p_clock_in_time then interval '1 day' else interval '0' end)
    at time zone v_timezone;
  if v_clock_out_at<=v_clock_in_at or v_clock_out_at-v_clock_in_at>interval '24 hours' then
    return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.');
  end if;

  if v_clock_in_at>clock_timestamp() or v_clock_out_at>clock_timestamp() then
    return jsonb_build_object('ok',false,'code','future_time','message','현재 시각 이후의 출근·퇴근시간은 입력할 수 없습니다.');
  end if;

  update public.work_sessions set
    clock_in_at=v_clock_in_at,
    clock_out_at=v_clock_out_at,
    status='completed'
  where id=v_target.id and property_id=v_owner_session.property_id;

  update public.attendance_adjustment_requests set
    requested_clock_in_at=v_clock_in_at,
    requested_clock_out_at=v_clock_out_at,
    status='approved',
    approved_at=clock_timestamp(),
    approved_by=v_owner_session.owner_id
  where work_session_id=v_target.id and status<>'rejected';

  update public.urgent_messages set
    acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_by=coalesce(acknowledged_by,v_owner_session.owner_id)
  where attendance_request_id in (
    select r.id from public.attendance_adjustment_requests r
    where r.work_session_id=v_target.id
  );

  return jsonb_build_object(
    'ok',true,
    'status','updated',
    'work_session_id',v_target.id,
    'clock_in_at',v_clock_in_at,
    'clock_out_at',v_clock_out_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.request_attendance_adjustment(p_access_token uuid, p_work_session_id uuid, p_clock_in_time time without time zone, p_clock_out_time time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_login public.work_sessions%rowtype;v_target public.work_sessions%rowtype;v_employee_name text;v_timezone text;
  v_requested_clock_in_at timestamptz;v_requested_clock_out_at timestamptz;v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_login from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 수정 요청할 수 있습니다.'); end if;
  select s.* into v_target from public.work_sessions s where s.id=p_work_session_id and s.property_id=v_login.property_id and s.employee_id=v_login.employee_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 근무 기록을 찾을 수 없습니다.'); end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_target.property_id;
  if p_clock_in_time is null or p_clock_out_time is null then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  v_requested_clock_in_at:=(v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_requested_clock_out_at:=(v_target.work_date+p_clock_out_time+case when p_clock_out_time<=p_clock_in_time then interval '1 day' else interval '0' end) at time zone v_timezone;
  if v_requested_clock_out_at-v_requested_clock_in_at>interval '24 hours' then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  if v_requested_clock_in_at>clock_timestamp() or v_requested_clock_out_at>clock_timestamp() then return jsonb_build_object('ok',false,'code','future_time','message','현재 시각 이후의 출근·퇴근시간은 입력할 수 없습니다.'); end if;
  if exists(select 1 from public.attendance_adjustment_requests r where r.work_session_id=v_target.id and r.status<>'rejected') then return jsonb_build_object('ok',false,'code','already_requested','message','이미 제출된 수정 요청이 있습니다.'); end if;
  insert into public.attendance_adjustment_requests(business_id,property_id,employee_id,work_session_id,original_clock_in_at,original_clock_out_at,requested_clock_in_at,requested_clock_out_at)
  values(v_target.business_id,v_target.property_id,v_target.employee_id,v_target.id,v_target.clock_in_at,v_target.clock_out_at,v_requested_clock_in_at,v_requested_clock_out_at) returning id into v_request_id;
  select e.display_name into v_employee_name from public.employees e where e.id=v_target.employee_id;
  v_message:=format(E'출퇴근 시간 수정 요청\n근무일: %s\n기존: %s ~ %s\n요청: %s ~ %s',v_target.work_date,
    to_char(v_target.clock_in_at at time zone v_timezone,'HH24:MI'),coalesce(to_char(v_target.clock_out_at at time zone v_timezone,'HH24:MI'),'-'),
    to_char(v_requested_clock_in_at at time zone v_timezone,'HH24:MI'),to_char(v_requested_clock_out_at at time zone v_timezone,'HH24:MI'));
  insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type,attendance_request_id)
  values(v_target.business_id,v_target.property_id,'staff',v_target.employee_id,v_message,'normal','attendance_approval',v_request_id) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select distinct v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.active and(o.property_id=v_target.property_id or exists(
    select 1 from public.property_share_requests r where r.target_property_id=v_target.property_id and r.requester_property_id=o.property_id
      and r.status='approved' and 'messages'=any(r.requested_permissions)));
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending','employee_name',v_employee_name);
end;
$function$
;

