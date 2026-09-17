-- After 003_staff_sessions.sql: enter new, distinct PINs in SQL Editor only.
-- Do not commit the filled-in file or share its screenshot.
-- Rotate the exposed test PINs and activate the seven RPCs in one transaction.
begin;
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
