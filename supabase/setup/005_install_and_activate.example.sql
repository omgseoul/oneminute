-- OMG Works: 기능 설치 + PIN 변경 + 앱 연결 활성화
-- 기본 테이블과 초기 직원 PIN 등록을 완료한 프로젝트에서 실행합니다.
-- 아래 PIN 자리 네 곳에 기존과 다른 숫자 6~8자리를 직접 입력하세요.
-- 직원별 PIN은 서로 다르게 정하고, 입력한 코드나 화면은 공유하지 마세요.
-- 전체 코드를 한 번에 실행하세요. 실패하면 이 작업 전체가 취소됩니다.
-- 근무기록은 삭제하지 않습니다. 중복 근무 검사 인덱스만 교체합니다.

begin;

create schema if not exists omg_private;
revoke all on schema omg_private from public, anon, authenticated;

alter table public.employees
  add column if not exists login_failures integer not null default 0,
  add column if not exists login_locked_until timestamptz;
alter table public.work_sessions
  add column if not exists token_expires_at timestamptz not null default '-infinity';
alter table public.work_reports
  add column if not exists make_accepted_at timestamptz;

-- Replace the index only; keep every attendance row and unknown checkout time.
drop index if exists public.one_open_work_session_per_employee;
create unique index one_open_work_session_per_employee
  on public.work_sessions(employee_id)
  where clock_out_at is null and status = 'working';
create unique index if not exists work_session_token_unique
  on public.work_sessions(login_token_hash);
create unique index if not exists one_report_per_session_and_type
  on public.work_reports(work_session_id, report_type);

create or replace function omg_private.token_hash(p_token uuid)
returns text language sql immutable strict set search_path = '' as $$
  select encode(sha256(convert_to(p_token::text, 'UTF8')), 'hex');
$$;

create or replace function omg_private.pin_matches(p_pin text, p_hash text)
returns boolean language plpgsql strict set search_path = '' as $$
declare v_schema text; v_matches boolean;
begin
  select n.nspname into strict v_schema
  from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid = x.extnamespace
  where x.extname = 'pgcrypto';
  execute format('select %I.crypt($1, $2) = $2', v_schema)
    into v_matches using p_pin, p_hash;
  return coalesce(v_matches, false);
end;
$$;

create or replace function omg_private.session_result(p_session_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'ok', true, 'session_id', s.id, 'employee_id', e.id,
    'employee_name', e.display_name, 'role', e.role,
    'business_id', s.business_id, 'property_id', s.property_id, 'timezone', p.timezone,
    'shift', s.shift, 'work_date', s.work_date,
    'clock_in_at', s.clock_in_at, 'clock_out_at', s.clock_out_at,
    'expires_at', s.token_expires_at, 'status', s.status,
    'checkin_report_at', s.checkin_report_at,
    'checkout_report_at', s.checkout_report_at
  )
  from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  join public.properties p on p.id = s.property_id
  where s.id = p_session_id;
$$;

create or replace function public.list_login_employees(
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns table(employee_id uuid, display_name text)
language sql security definer set search_path = '' as $$
  select e.id, e.display_name from public.employees e
  join public.properties p on p.id = e.property_id and p.business_id = e.business_id
  join public.businesses b on b.id = e.business_id
  where b.code = p_business_code and p.code = p_property_code
    and e.active and e.pin_hash is not null
  order by e.display_name, e.id;
$$;

create or replace function public.start_work_session(
  p_employee_id uuid, p_pin text, p_shift text,
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
begin
  if p_employee_id is null or p_pin is null
     or p_pin !~ '^[0-9]{6,8}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '직원과 PIN을 확인해주세요.');
  end if;
  if p_shift is null or p_shift not in ('morning', 'afternoon') then
    return jsonb_build_object('ok', false, 'code', 'invalid_shift',
      'message', '오전 또는 오후 근무를 선택해주세요.');
  end if;

  -- Serialize attempts for this employee, including failure-counter updates.
  select e.* into v_employee from public.employees e
  join public.properties p on p.id = e.property_id and p.business_id = e.business_id
  join public.businesses b on b.id = e.business_id
  where e.id = p_employee_id and e.active and e.pin_hash is not null
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
    if v_session.work_date < v_date
       or v_session.clock_in_at < v_now - interval '20 hours' then
      update public.work_sessions set status = 'needs_review', token_expires_at = v_now
        where id = v_session.id;
      v_session.id := null;
    elsif v_session.shift <> p_shift then
      return jsonb_build_object('ok', false, 'code', 'shift_conflict',
        'message', '진행 중인 근무가 있습니다. 같은 근무 구분으로 로그인해주세요.');
    else
      v_resumed := true;
    end if;
  end if;

  if v_session.id is null then
    insert into public.work_sessions
      (business_id, property_id, employee_id, shift, work_date,
       clock_in_at, login_token_hash, token_expires_at)
    values (v_employee.business_id, v_employee.property_id, v_employee.id,
      p_shift, v_date, v_now, omg_private.token_hash(v_token), v_now + interval '20 hours')
    returning * into v_session;
  else
    update public.work_sessions set login_token_hash = omg_private.token_hash(v_token),
      token_expires_at = least(v_now + interval '20 hours', clock_in_at + interval '20 hours')
    where id = v_session.id returning * into v_session;
  end if;
  return omg_private.session_result(v_session.id)
    || jsonb_build_object('access_token', v_token, 'resumed', v_resumed);
end;
$$;

create or replace function public.get_work_session(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select s.id into v_id from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  return omg_private.session_result(v_id);
end;
$$;

create or replace function public.end_device_session(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  -- Device logout is not a clock-out and never invents a checkout time.
  update public.work_sessions set token_expires_at = clock_timestamp()
    where login_token_hash = omg_private.token_hash(p_access_token);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.save_work_report(
  p_access_token uuid, p_report_type text, p_payload jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_session public.work_sessions%rowtype;
  v_report public.work_reports%rowtype;
  v_employee_name text;
  v_now timestamptz;
  v_payload jsonb;
  v_existing boolean;
begin
  if p_report_type is null or p_report_type not in ('clock_in', 'clock_out')
     or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 20971520 then
    return jsonb_build_object('ok', false, 'code', 'invalid_report',
      'message', '보고서 형식 또는 사진 용량을 확인해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed') for update of s;
  if not found or v_session.token_expires_at <= clock_timestamp() then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;

  select r.* into v_report from public.work_reports r
    where r.work_session_id = v_session.id and r.report_type = p_report_type;
  v_existing := found;
  if not v_existing then
    if v_session.status <> 'working' or v_session.clock_out_at is not null then
      return jsonb_build_object('ok', false, 'code', 'session_completed',
        'message', '이미 종료된 근무입니다.');
    end if;
    v_now := clock_timestamp();
    select e.display_name into v_employee_name from public.employees e
      where e.id = v_session.employee_id;
    v_report.id := gen_random_uuid();
    v_payload := p_payload || jsonb_build_object(
      'worker', v_employee_name,
      'shift', case when v_session.shift = 'morning' then '오전' else '오후' end,
      'report_type', case when p_report_type = 'clock_in' then '출근보고' else '퇴근보고' end,
      'report_id', v_report.id, 'work_session_id', v_session.id,
      'work_date', v_session.work_date, 'attendance_clock_in_at', v_session.clock_in_at,
      'submitted_at', v_now
    );
    insert into public.work_reports
      (id, work_session_id, business_id, property_id, employee_id, report_type, payload, submitted_at)
    values (v_report.id, v_session.id, v_session.business_id, v_session.property_id,
      v_session.employee_id, p_report_type, v_payload, v_now)
    returning * into v_report;
    if p_report_type = 'clock_in' then
      update public.work_sessions set checkin_report_at = v_now where id = v_session.id;
    else
      update public.work_sessions set checkout_report_at = v_now, clock_out_at = v_now,
        status = 'completed' where id = v_session.id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'report_id', v_report.id,
    'already_saved', v_existing, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$$;

create or replace function public.get_work_report(p_access_token uuid, p_report_type text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_report public.work_reports%rowtype;
begin
  if p_report_type is null or p_report_type not in ('clock_in', 'clock_out') then
    return jsonb_build_object('ok', false, 'code', 'invalid_report');
  end if;
  if (public.get_work_session(p_access_token)->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  select r.* into v_report from public.work_reports r
  join public.work_sessions s on s.id = r.work_session_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and r.report_type = p_report_type;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'report_id', v_report.id,
    'already_saved', true, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$$;

create or replace function public.mark_report_delivered(p_access_token uuid, p_report_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  update public.work_reports r set make_accepted_at = coalesce(r.make_accepted_at, clock_timestamp())
  from public.work_sessions s join public.employees e on e.id = s.employee_id
  where r.id = p_report_id and r.work_session_id = s.id
    and s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '전송 상태를 저장하지 못했습니다. 다시 로그인해주세요.');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on all functions in schema omg_private from public, anon, authenticated;
revoke all on function public.list_login_employees(text, text) from public, anon, authenticated;
revoke all on function public.start_work_session(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.get_work_session(uuid) from public, anon, authenticated;
revoke all on function public.end_device_session(uuid) from public, anon, authenticated;
revoke all on function public.save_work_report(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.get_work_report(uuid, text) from public, anon, authenticated;
revoke all on function public.mark_report_delivered(uuid, uuid) from public, anon, authenticated;


-- 직원별 새 PIN 입력 및 연결 활성화

set local search_path = '';

do $activate$
declare
  v_staff record;
  v_employee public.employees%rowtype;
  v_schema text;
  v_hash text;
  v_seen text[] := array[]::text[];
begin
  select n.nspname into strict v_schema
  from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid = x.extnamespace
  where x.extname = 'pgcrypto';
  for v_staff in
    select * from (values
      ('변지훈', 'NEW_PIN_1'),
      ('문정국', 'NEW_PIN_2'),
      ('신옥재', 'NEW_PIN_3'),
      ('정준하', 'NEW_PIN_4')
    ) as input(display_name, pin)
  loop
    if not coalesce(v_staff.pin ~ '^[0-9]{6,8}$', false)
       or v_staff.pin = any(v_seen) then
      raise exception '직원별로 서로 다른 숫자 6~8자리 PIN을 입력해주세요.';
    end if;
    v_seen := array_append(v_seen, v_staff.pin);
    select e.* into strict v_employee from public.employees e
    join public.properties p on p.id = e.property_id and p.business_id = e.business_id
    join public.businesses b on b.id = e.business_id
    where b.code = 'omg' and p.code = 'seoul-station'
      and e.display_name = v_staff.display_name and e.active
    for update of e;
    if omg_private.pin_matches(v_staff.pin, v_employee.pin_hash) is true then
      raise exception '%: 기존 테스트 PIN과 다른 PIN을 입력해주세요.', v_staff.display_name;
    end if;
    execute format('select %I.crypt($1, %I.gen_salt(''bf'',10))', v_schema, v_schema)
      into v_hash using v_staff.pin;
    update public.employees set pin_hash = v_hash,
      login_failures = 0, login_locked_until = null where id = v_employee.id;
    update public.work_sessions set token_expires_at = clock_timestamp()
      where employee_id = v_employee.id;
  end loop;
end;
$activate$;

grant execute on function
  public.list_login_employees(text, text),
  public.start_work_session(uuid, text, text, text, text),
  public.get_work_session(uuid),
  public.end_device_session(uuid),
  public.save_work_report(uuid, text, jsonb),
  public.get_work_report(uuid, text),
  public.mark_report_delivered(uuid, uuid)
to anon, authenticated;

commit;

select p.proname as function_name,
  has_function_privilege('anon', p.oid, 'EXECUTE')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE') as api_ready
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'list_login_employees', 'start_work_session', 'get_work_session',
  'end_device_session', 'save_work_report', 'get_work_report', 'mark_report_delivered'
)
order by p.proname;

