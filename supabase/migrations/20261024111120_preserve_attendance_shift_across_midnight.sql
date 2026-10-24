-- Confirmed attendance and NFC entry belong to a shift, including across midnight.
-- Report offsets must not extend or shorten the existing 20-hour login lifetime.
create or replace function public.start_work_session(
  p_employee_id uuid, p_pin text, p_shift text default 'general',
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_employee public.employees%rowtype;
  v_session public.work_sessions%rowtype;
  v_token uuid := gen_random_uuid();
  v_now timestamptz;
  v_timezone text;
  v_date date;
  v_failures integer;
  v_resumed boolean := false;
  v_warnings jsonb;
begin
  if p_employee_id is null or p_pin is null or p_pin !~ '^[0-9]{6,8}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '직원과 PIN을 확인해주세요.');
  end if;

  select e.* into v_employee from public.employees e
  join public.properties p on p.id = e.property_id and p.business_id = e.business_id
  join public.businesses b on b.id = e.business_id
  where e.id = p_employee_id and e.active and e.pin_hash is not null
    and e.role <> 'owner'
    and b.code = p_business_code and p.code = p_property_code
  for update of e;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '직원과 PIN을 확인해주세요.');
  end if;

  v_now := clock_timestamp();
  if v_employee.login_locked_until > v_now then
    return jsonb_build_object('ok', false, 'code', 'locked',
      'message', 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');
  end if;
  v_failures := case when v_employee.login_locked_until is not null
    then 0 else v_employee.login_failures end;
  if omg_private.pin_matches(p_pin, v_employee.pin_hash) is not true then
    v_failures := v_failures + 1;
    update public.employees set login_failures = v_failures,
      login_locked_until = case when v_failures >= 5
        then v_now + interval '15 minutes' else null end
    where id = v_employee.id;
    return jsonb_build_object('ok', false,
      'code', case when v_failures >= 5 then 'locked' else 'invalid_credentials' end,
      'message', case when v_failures >= 5
        then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.'
        else '직원과 PIN을 확인해주세요.' end);
  end if;
  update public.employees set login_failures = 0, login_locked_until = null
    where id = v_employee.id;

  select p.timezone into v_timezone from public.properties p
    where p.id = v_employee.property_id;
  v_now := clock_timestamp();
  v_date := (v_now at time zone v_timezone)::date;
  select s.* into v_session from public.work_sessions s
  where s.employee_id = v_employee.id and s.status = 'working'
    and s.clock_out_at is null for update;
  if found then
    if (v_session.work_date < v_date and v_session.checkin_report_at is null and v_session.nfc_entry_at is null)
       or coalesce(v_session.first_login_at,v_session.clock_in_at) < v_now - interval '20 hours' then
      update public.work_sessions set status = 'needs_review', token_expires_at = v_now
        where id = v_session.id;
      v_session.id := null;
    else
      v_resumed := true;
    end if;
  end if;

  if v_session.id is null then
    insert into public.work_sessions
      (business_id, property_id, employee_id, shift, work_date,
       clock_in_at, login_token_hash, token_expires_at)
    values (v_employee.business_id, v_employee.property_id, v_employee.id,
      'general', v_date, v_now, omg_private.token_hash(v_token), v_now + interval '20 hours')
    returning * into v_session;
  else
    update public.work_sessions set login_token_hash = omg_private.token_hash(v_token),
      token_expires_at = least(v_now + interval '20 hours', coalesce(first_login_at,clock_in_at) + interval '20 hours')
    where id = v_session.id returning * into v_session;
  end if;
  v_warnings:=public.evaluate_attendance_warnings(v_token,'login');
  return omg_private.session_result(v_session.id)
    || jsonb_build_object('access_token', v_token, 'resumed', v_resumed,'warning_message_ids',coalesce(v_warnings->'message_ids','[]'::jsonb));
end;
$$;
