-- Initial PIN registration only. Replace PIN_1 ... PIN_4 in the SQL Editor.
-- Use different 6-8 digit PINs. Never commit the filled-in version.
-- Existing PINs are not overwritten; any error rolls back the whole setup.
begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
set local search_path = '';

do $setup$
declare
  v_staff record;
  v_crypto_schema text;
  v_hash text;
  v_changed integer;
begin
  select n.nspname into strict v_crypto_schema
  from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid = x.extnamespace
  where x.extname = 'pgcrypto';

  for v_staff in
    select * from (values
      ('변지훈', 'PIN_1'),
      ('문정국', 'PIN_2'),
      ('신옥재', 'PIN_3'),
      ('정준하', 'PIN_4')
    ) as staff(display_name, pin)
  loop
    if not coalesce(v_staff.pin ~ '^[0-9]{6,8}$', false) then
      raise exception '%: PIN을 숫자 6~8자리로 바꿔주세요.', v_staff.display_name;
    end if;

    execute format(
      'select %I.crypt($1, %I.gen_salt(''bf'', 10))',
      v_crypto_schema, v_crypto_schema
    ) into v_hash using v_staff.pin;

    update public.employees e
    set pin_hash = v_hash
    from public.properties p
    join public.businesses b on b.id = p.business_id
    where e.property_id = p.id
      and e.business_id = b.id
      and b.code = 'omg'
      and p.code = 'seoul-station'
      and e.display_name = v_staff.display_name
      and e.active = true
      and e.pin_hash is null;

    get diagnostics v_changed = row_count;
    if v_changed <> 1 then
      raise exception '%: 직원이 없거나 중복되거나 이미 PIN이 등록돼 있습니다. 변경을 취소합니다.', v_staff.display_name;
    end if;
  end loop;
end;
$setup$;

commit;

select e.display_name, (e.pin_hash is not null) as pin_ready
from public.employees e
join public.properties p on p.id = e.property_id
join public.businesses b on b.id = e.business_id
where b.code = 'omg' and p.code = 'seoul-station'
  and e.display_name in ('변지훈', '문정국', '신옥재', '정준하')
order by e.display_name;
