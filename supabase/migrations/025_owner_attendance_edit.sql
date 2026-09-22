-- Allow an authenticated property owner to correct attendance for their own property.
begin;

create or replace function public.owner_update_attendance(
  p_access_token uuid,
  p_work_session_id uuid,
  p_clock_in_time time,
  p_clock_out_time time
)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  where work_session_id=v_target.id;

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
$$;

revoke all on function public.owner_update_attendance(uuid,uuid,time,time) from public;
grant execute on function public.owner_update_attendance(uuid,uuid,time,time) to anon,authenticated;

commit;
select '관리자 근무시간 직접 수정 준비 완료' as result;
