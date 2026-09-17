-- Property/room settings and per-employee report fields.
-- Safe to run after the confirmed session/report installation.
begin;

alter table public.properties
  add column if not exists rooms jsonb not null default '[]'::jsonb;

alter table public.employees
  add column if not exists report_config jsonb not null default
    '{"clock_in":["clean_rooms","inspect_rooms","no_show","bedding_stain"],"clock_out":["cleaned_rooms","inspected_rooms"]}'::jsonb;

create table if not exists public.owners (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  display_name text not null,
  login_id text not null,
  pin_hash text not null,
  active boolean not null default true,
  login_failures integer not null default 0,
  login_locked_until timestamptz,
  created_at timestamptz not null default now(),
  foreign key (business_id, property_id)
    references public.properties(business_id, id)
);

create unique index if not exists owner_login_per_business_unique
  on public.owners (business_id, lower(login_id));

create table if not exists public.owner_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.owners(id),
  business_id uuid not null,
  property_id uuid not null,
  login_token_hash text not null unique,
  token_expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  foreign key (business_id, property_id)
    references public.properties(business_id, id)
);

alter table public.owners enable row level security;
alter table public.owner_sessions enable row level security;
revoke all on table public.owners, public.owner_sessions
  from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'properties_rooms_array_check'
      and conrelid = 'public.properties'::regclass
  ) then
    alter table public.properties add constraint properties_rooms_array_check
      check (jsonb_typeof(rooms) = 'array');
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'employees_report_config_object_check'
      and conrelid = 'public.employees'::regclass
  ) then
    alter table public.employees add constraint employees_report_config_object_check
      check (jsonb_typeof(report_config) = 'object');
  end if;
end;
$$;

update public.properties p
set rooms = '["401","408","501","508","402","407","502","504","507","403","404","405","503","505","406","506"]'::jsonb
from public.businesses b
where p.business_id = b.id and b.code = 'omg' and p.code = 'seoul-station'
  and p.rooms = '[]'::jsonb;

alter table public.work_sessions drop constraint if exists work_sessions_shift_check;
alter table public.work_sessions add constraint work_sessions_shift_check
  check (shift in ('general','morning','afternoon'));

create or replace function omg_private.report_config_is_valid(p_config jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_config) = 'object'
    and jsonb_typeof(p_config -> 'clock_in') = 'array'
    and jsonb_typeof(p_config -> 'clock_out') = 'array'
    and jsonb_array_length(p_config -> 'clock_in') <= 4
    and jsonb_array_length(p_config -> 'clock_out') <= 2
    and not exists (
      select 1 from jsonb_array_elements_text(p_config -> 'clock_in') as item(value)
      where item.value <> all(array['clean_rooms','inspect_rooms','no_show','bedding_stain'])
    )
    and not exists (
      select 1 from jsonb_array_elements_text(p_config -> 'clock_out') as item(value)
      where item.value <> all(array['cleaned_rooms','inspected_rooms'])
    ), false
  );
$$;

create or replace function omg_private.session_result(p_session_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'ok', true, 'session_id', s.id, 'employee_id', e.id,
    'employee_name', e.display_name, 'role', e.role, 'session_kind', 'staff',
    'business_id', s.business_id, 'property_id', s.property_id,
    'property_name', p.name, 'report_config', e.report_config,
    'timezone', p.timezone, 'shift', s.shift, 'work_date', s.work_date,
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

create or replace function omg_private.owner_session_result(p_session_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'ok', true, 'session_id', s.id, 'owner_id', o.id,
    'employee_name', o.display_name, 'role', 'owner', 'session_kind', 'owner',
    'business_id', s.business_id, 'property_id', s.property_id,
    'property_name', p.name, 'timezone', p.timezone,
    'expires_at', s.token_expires_at, 'status', 'active'
  )
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  join public.properties p on p.id = s.property_id
  where s.id = p_session_id;
$$;

create or replace function public.get_login_property(
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('ok', true, 'property_name', p.name)
     from public.properties p
     join public.businesses b on b.id = p.business_id
     where b.code = p_business_code and p.code = p_property_code),
    jsonb_build_object('ok', false, 'code', 'not_found')
  );
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
    and e.active and e.pin_hash is not null and e.role <> 'owner'
  order by e.display_name, e.id;
$$;

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
    if v_session.work_date < v_date
       or v_session.clock_in_at < v_now - interval '20 hours' then
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
      token_expires_at = least(v_now + interval '20 hours', clock_in_at + interval '20 hours')
    where id = v_session.id returning * into v_session;
  end if;
  return omg_private.session_result(v_session.id)
    || jsonb_build_object('access_token', v_token, 'resumed', v_resumed);
end;
$$;

create or replace function public.start_owner_session(
  p_login_id text, p_pin text,
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_owner public.owners%rowtype;
  v_session public.owner_sessions%rowtype;
  v_token uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_failures integer;
begin
  if btrim(coalesce(p_login_id, '')) = '' or p_pin is null
     or p_pin !~ '^[0-9]{6,8}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '사장 아이디와 PIN을 확인해주세요.');
  end if;
  select o.* into v_owner from public.owners o
  join public.properties p on p.id = o.property_id and p.business_id = o.business_id
  join public.businesses b on b.id = o.business_id
  where lower(o.login_id) = lower(btrim(p_login_id)) and o.active
    and b.code = p_business_code and p.code = p_property_code
  for update of o;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '사장 아이디와 PIN을 확인해주세요.');
  end if;
  if v_owner.login_locked_until > v_now then
    return jsonb_build_object('ok', false, 'code', 'locked',
      'message', 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');
  end if;
  v_failures := case when v_owner.login_locked_until is not null
    then 0 else v_owner.login_failures end;
  if omg_private.pin_matches(p_pin, v_owner.pin_hash) is not true then
    v_failures := v_failures + 1;
    update public.owners set login_failures = v_failures,
      login_locked_until = case when v_failures >= 5
        then v_now + interval '15 minutes' else null end
    where id = v_owner.id;
    return jsonb_build_object('ok', false,
      'code', case when v_failures >= 5 then 'locked' else 'invalid_credentials' end,
      'message', case when v_failures >= 5
        then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.'
        else '사장 아이디와 PIN을 확인해주세요.' end);
  end if;
  update public.owners set login_failures = 0, login_locked_until = null
    where id = v_owner.id;
  insert into public.owner_sessions
    (owner_id, business_id, property_id, login_token_hash, token_expires_at)
  values (v_owner.id, v_owner.business_id, v_owner.property_id,
    omg_private.token_hash(v_token), v_now + interval '12 hours')
  returning * into v_session;
  return omg_private.owner_session_result(v_session.id)
    || jsonb_build_object('access_token', v_token);
end;
$$;

create or replace function public.get_app_session(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_owner_session_id uuid;
  v_work_session jsonb;
begin
  select s.id into v_owner_session_id
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and o.active;
  if found then
    return omg_private.owner_session_result(v_owner_session_id);
  end if;
  v_work_session := public.get_work_session(p_access_token);
  if (v_work_session ->> 'ok')::boolean is true then return v_work_session; end if;
  return jsonb_build_object('ok', false, 'code', 'invalid_session',
    'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
end;
$$;

create or replace function public.end_app_session(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  update public.owner_sessions set token_expires_at = clock_timestamp()
    where login_token_hash = omg_private.token_hash(p_access_token);
  update public.work_sessions set token_expires_at = clock_timestamp()
    where login_token_hash = omg_private.token_hash(p_access_token);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_session public.work_sessions%rowtype;
  v_employee public.employees%rowtype;
  v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;
  v_owner public.owners%rowtype;
  v_can_manage boolean := false;
  v_employees jsonb := '[]'::jsonb;
begin
  select s.* into v_owner_session
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and o.active;
  if found then
    select * into v_owner from public.owners where id = v_owner_session.owner_id;
    select * into v_property from public.properties where id = v_owner_session.property_id;
    v_can_manage := true;
  else
  select s.* into v_session
  from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working','completed');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  select * into v_employee from public.employees where id = v_session.employee_id;
  select * into v_property from public.properties where id = v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object(
      'employee_id', e.id, 'display_name', e.display_name,
      'role', e.role, 'report_config', e.report_config
    ) order by e.display_name, e.id), '[]'::jsonb)
    into v_employees from public.employees e
    where e.property_id = v_property.id and e.active and e.role <> 'owner';
  end if;
  return jsonb_build_object(
    'ok', true,
    'property', jsonb_build_object('property_id', v_property.id,
      'name', v_property.name, 'rooms', v_property.rooms),
    'report_config', case when v_can_manage then null else v_employee.report_config end,
    'employees', v_employees,
    'can_manage', v_can_manage
  );
end;
$$;

create or replace function public.save_property_settings(
  p_access_token uuid,
  p_property_name text,
  p_rooms jsonb,
  p_employee_configs jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_property_id uuid;
  v_name text := btrim(coalesce(p_property_name, ''));
  v_rooms jsonb;
  v_pair record;
  v_employee_id uuid;
begin
  select s.property_id into v_property_id
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and o.active;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'owner_required',
      'message', '사장 계정만 설정을 변경할 수 있습니다.');
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name',
      'message', '숙소 이름은 1~80자로 입력해주세요.');
  end if;
  if jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) < 1
     or jsonb_array_length(p_rooms) > 100 then
    return jsonb_build_object('ok', false, 'code', 'invalid_rooms',
      'message', '객실명을 1개 이상 100개 이하로 입력해주세요.');
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(p_rooms) as room(value)
    where btrim(room.value) = '' or char_length(btrim(room.value)) > 30
  ) then
    return jsonb_build_object('ok', false, 'code', 'invalid_rooms',
      'message', '객실명은 각각 1~30자로 입력해주세요.');
  end if;
  select jsonb_agg(room order by first_position) into v_rooms
  from (
    select btrim(value) as room, min(position) as first_position
    from jsonb_array_elements_text(p_rooms) with ordinality as item(value, position)
    group by btrim(value)
  ) normalized;
  if jsonb_typeof(p_employee_configs) <> 'object' then
    return jsonb_build_object('ok', false, 'code', 'invalid_employee_config',
      'message', '직원별 보고 항목을 확인해주세요.');
  end if;

  for v_pair in select * from jsonb_each(p_employee_configs)
  loop
    begin
      v_employee_id := v_pair.key::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok', false, 'code', 'invalid_employee_config',
        'message', '직원별 보고 항목을 확인해주세요.');
    end;
    if omg_private.report_config_is_valid(v_pair.value) is not true then
      return jsonb_build_object('ok', false, 'code', 'invalid_employee_config',
        'message', '직원별 보고 항목을 확인해주세요.');
    end if;
    if not exists (
      select 1 from public.employees
      where id = v_employee_id and property_id = v_property_id and active
    ) then
      return jsonb_build_object('ok', false, 'code', 'unknown_employee',
        'message', '존재하지 않는 직원이 포함되어 있습니다.');
    end if;
  end loop;

  for v_pair in select * from jsonb_each(p_employee_configs)
  loop
    update public.employees set report_config = v_pair.value
    where id = v_pair.key::uuid and property_id = v_property_id and active;
  end loop;

  update public.properties set name = v_name, rooms = v_rooms
    where id = v_property_id;
  return public.get_work_app_config(p_access_token);
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
      'message', '보고서 형식을 확인해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed') for update of s;
  if not found then
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
      'worker', v_employee_name, 'shift', '근무',
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

revoke all on function omg_private.report_config_is_valid(jsonb) from public, anon, authenticated;
revoke all on function omg_private.owner_session_result(uuid) from public, anon, authenticated;
revoke all on function public.get_login_property(text,text) from public;
revoke all on function public.start_owner_session(text,text,text,text) from public;
revoke all on function public.get_app_session(uuid) from public;
revoke all on function public.end_app_session(uuid) from public;
revoke all on function public.get_work_app_config(uuid) from public;
revoke all on function public.save_property_settings(uuid,text,jsonb,jsonb) from public;
grant execute on function public.get_login_property(text,text) to anon, authenticated;
grant execute on function public.list_login_employees(text,text) to anon, authenticated;
grant execute on function public.start_work_session(uuid,text,text,text,text) to anon, authenticated;
grant execute on function public.start_owner_session(text,text,text,text) to anon, authenticated;
grant execute on function public.get_app_session(uuid) to anon, authenticated;
grant execute on function public.end_app_session(uuid) to anon, authenticated;
grant execute on function public.get_work_session(uuid) to anon, authenticated;
grant execute on function public.end_device_session(uuid) to anon, authenticated;
grant execute on function public.save_work_report(uuid,text,jsonb) to anon, authenticated;
grant execute on function public.get_work_report(uuid,text) to anon, authenticated;
grant execute on function public.mark_report_delivered(uuid,uuid) to anon, authenticated;
grant execute on function public.get_work_app_config(uuid) to anon, authenticated;
grant execute on function public.save_property_settings(uuid,text,jsonb,jsonb) to anon, authenticated;

commit;

select '숙소·객실·직원별 보고 설정 준비 완료' as result;
