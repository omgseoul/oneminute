-- Owner-only attendance history and duration statistics.
begin;

create or replace function public.list_attendance_statistics(
  p_access_token uuid,
  p_from_date date,
  p_to_date date
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_property_id uuid;
  v_timezone text;
  v_sessions jsonb := '[]'::jsonb;
  v_employees jsonb := '[]'::jsonb;
begin
  select s.property_id,p.timezone
  into v_property_id,v_timezone
  from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  join public.properties p on p.id=s.property_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp()
    and o.active;

  if not found then
    return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무시간을 확인할 수 있습니다.');
  end if;
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'code','invalid_period','message','조회 기간을 확인해주세요.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id',s.id,
    'employee_id',s.employee_id,
    'employee_name',e.display_name,
    'work_date',s.work_date,
    'clock_in_at',s.clock_in_at,
    'clock_out_at',s.clock_out_at,
    'duration_minutes',case when s.clock_out_at is null then null else greatest(0,floor(extract(epoch from (s.clock_out_at-s.clock_in_at))/60)::integer) end,
    'status',s.status,
    'checkin_report_at',s.checkin_report_at,
    'checkout_report_at',s.checkout_report_at
  ) order by s.work_date desc,s.clock_in_at desc),'[]'::jsonb)
  into v_sessions
  from public.work_sessions s
  join public.employees e on e.id=s.employee_id
  where s.property_id=v_property_id
    and s.work_date between p_from_date and p_to_date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',e.id,
    'display_name',e.display_name,
    'active',e.active
  ) order by e.active desc,e.created_at,e.id),'[]'::jsonb)
  into v_employees
  from public.employees e
  where e.property_id=v_property_id
    and e.role<>'owner'
    and (e.active or exists(
      select 1 from public.work_sessions s
      where s.employee_id=e.id and s.work_date between p_from_date and p_to_date
    ));

  return jsonb_build_object(
    'ok',true,
    'timezone',v_timezone,
    'from_date',p_from_date,
    'to_date',p_to_date,
    'employees',v_employees,
    'sessions',v_sessions
  );
end;
$$;

revoke all on function public.list_attendance_statistics(uuid,date,date) from public;
grant execute on function public.list_attendance_statistics(uuid,date,date) to anon,authenticated;

commit;
select '직원 출퇴근 통계 준비 완료' as result;
