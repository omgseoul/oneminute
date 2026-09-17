-- One-time owner account setup.
-- Replace OWNER_LOGIN_ID and OWNER_PIN_6_TO_8 only inside Supabase SQL Editor.
-- Never send the completed query or PIN through chat.
begin;

do $$
declare
  v_business_id uuid;
  v_property_id uuid;
  v_crypto_schema text;
  v_pin_hash text;
  v_login_id text := 'OWNER_LOGIN_ID';
  v_pin text := 'OWNER_PIN_6_TO_8';
begin
  if v_login_id !~ '^[A-Za-z0-9._-]{3,50}$' then
    raise exception '사장 아이디는 영문, 숫자, 점, 밑줄, 하이픈 3~50자로 입력해주세요.';
  end if;
  if v_pin !~ '^[0-9]{6,8}$' then
    raise exception '사장 PIN은 숫자 6~8자리로 입력해주세요.';
  end if;

  select b.id, p.id into strict v_business_id, v_property_id
  from public.businesses b
  join public.properties p on p.business_id = b.id
  where b.code = 'omg' and p.code = 'seoul-station';

  select n.nspname into strict v_crypto_schema
  from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid = x.extnamespace
  where x.extname = 'pgcrypto';
  execute format('select %I.crypt($1, %I.gen_salt(''bf''))',
    v_crypto_schema, v_crypto_schema) into v_pin_hash using v_pin;

  if exists (
    select 1 from public.owners
    where business_id = v_business_id and lower(login_id) = lower(v_login_id)
  ) then
    update public.owners
    set property_id = v_property_id, display_name = '사장',
      login_id = v_login_id, pin_hash = v_pin_hash, active = true,
      login_failures = 0, login_locked_until = null
    where business_id = v_business_id and lower(login_id) = lower(v_login_id);
  else
    insert into public.owners
      (business_id, property_id, display_name, login_id, pin_hash)
    values (v_business_id, v_property_id, '사장', v_login_id, v_pin_hash);
  end if;
end;
$$;

commit;

select display_name, login_id, active
from public.owners
where business_id = (select id from public.businesses where code = 'omg');
