-- Bind each authenticated email account to one property and provision new properties safely.
begin;

create table if not exists public.account_properties (
  user_id uuid primary key,
  business_id uuid not null references public.businesses(id),
  property_id uuid not null references public.properties(id),
  owner_id uuid not null references public.owners(id),
  onboarding_pending boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, property_id)
);

alter table public.account_properties enable row level security;
revoke all on table public.account_properties from public, anon, authenticated;

-- Preserve and attach the original One Minute data to its existing email account.
insert into public.account_properties(user_id,business_id,property_id,owner_id,onboarding_pending)
select u.id,b.id,p.id,o.id,false
from auth.users u
join public.businesses b on b.code='omg'
join public.properties p on p.business_id=b.id and p.code='seoul-station'
join lateral (
  select candidate.id from public.owners candidate
  where candidate.business_id=b.id and candidate.property_id=p.id and candidate.active
  order by candidate.created_at,candidate.id limit 1
) o on true
where lower(u.email)=lower('oneminute01@naver.com')
on conflict (user_id) do update set
  business_id=excluded.business_id,property_id=excluded.property_id,owner_id=excluded.owner_id,
  onboarding_pending=false,updated_at=clock_timestamp();

create or replace function public.get_or_create_account_property()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_user_id uuid:=auth.uid();v_email text:=lower(coalesce(auth.jwt()->>'email',''));
  v_link public.account_properties%rowtype;v_business_id uuid;v_property_id uuid;v_owner_id uuid;
  v_business_code text;v_property_code text;v_property_name text;v_crypto_schema text;v_pin_hash text;
  v_management_number integer;v_created boolean:=false;
begin
  if v_user_id is null then
    return jsonb_build_object('ok',false,'code','authentication_required','message','계정 로그인이 필요합니다.');
  end if;
  perform pg_advisory_xact_lock(hashtext(v_user_id::text));
  select * into v_link from public.account_properties where user_id=v_user_id;
  if not found and v_email='oneminute01@naver.com' then
    select b.id,p.id,o.id into v_business_id,v_property_id,v_owner_id
    from public.businesses b join public.properties p on p.business_id=b.id
    join lateral(select id from public.owners where business_id=b.id and property_id=p.id and active order by created_at,id limit 1)o on true
    where b.code='omg' and p.code='seoul-station';
    if found then
      insert into public.account_properties(user_id,business_id,property_id,owner_id,onboarding_pending)
      values(v_user_id,v_business_id,v_property_id,v_owner_id,false)
      on conflict(user_id) do nothing;
      select * into v_link from public.account_properties where user_id=v_user_id;
    end if;
  end if;
  if not found then
    v_created:=true;
    v_business_code:='account-'||replace(v_user_id::text,'-','');
    insert into public.businesses(name,code) values('새 숙소',v_business_code) returning id into v_business_id;
    perform pg_advisory_xact_lock(82424015);
    select coalesce(max(management_number),0)+1 into v_management_number from public.properties;
    insert into public.properties(business_id,name,code,rooms,room_types,management_number,notice)
    values(v_business_id,'새 숙소','main','[]'::jsonb,'[]'::jsonb,v_management_number,'') returning id into v_property_id;
    select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
    join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
    execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema)
      into v_pin_hash using '1234';
    insert into public.owners(business_id,property_id,display_name,login_id,pin_hash,active)
    values(v_business_id,v_property_id,'관리자','admin',v_pin_hash,true) returning id into v_owner_id;
    insert into public.account_properties(user_id,business_id,property_id,owner_id,onboarding_pending)
    values(v_user_id,v_business_id,v_property_id,v_owner_id,true) returning * into v_link;
  end if;
  select b.code,p.code,p.name into v_business_code,v_property_code,v_property_name
  from public.businesses b join public.properties p on p.business_id=b.id
  where b.id=v_link.business_id and p.id=v_link.property_id;
  return jsonb_build_object('ok',true,'business_code',v_business_code,'property_code',v_property_code,
    'property_name',v_property_name,'onboarding_pending',v_link.onboarding_pending,'created',v_created);
end;
$$;

create or replace function public.acknowledge_account_onboarding()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  update public.account_properties set onboarding_pending=false,updated_at=clock_timestamp() where user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.list_account_login_employees()
returns table(employee_id uuid,display_name text)
language sql security definer set search_path='' as $$
  select e.id,e.display_name from public.account_properties a
  join public.employees e on e.business_id=a.business_id and e.property_id=a.property_id
  where a.user_id=auth.uid() and e.active and e.pin_hash is not null and e.role<>'owner'
  order by e.display_name,e.id;
$$;

create or replace function public.list_account_login_admins()
returns table(owner_id uuid,display_name text)
language sql security definer set search_path='' as $$
  select o.id,o.display_name from public.account_properties a
  join public.owners o on o.business_id=a.business_id and o.property_id=a.property_id
  where a.user_id=auth.uid() and o.active order by o.created_at,o.id;
$$;

create or replace function public.start_account_work_session(p_employee_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_code text;v_property_code text;
begin
  select b.code,p.code into v_business_code,v_property_code from public.account_properties a
  join public.businesses b on b.id=a.business_id join public.properties p on p.id=a.property_id
  where a.user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'code','account_property_required','message','숙소 정보를 찾을 수 없습니다.');end if;
  return public.start_work_session(p_employee_id,p_pin,'general',v_business_code,v_property_code);
end;
$$;

create or replace function public.start_account_admin_session(p_owner_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_code text;v_property_code text;
begin
  select b.code,p.code into v_business_code,v_property_code from public.account_properties a
  join public.businesses b on b.id=a.business_id join public.properties p on p.id=a.property_id
  where a.user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'code','account_property_required','message','숙소 정보를 찾을 수 없습니다.');end if;
  return public.start_admin_session(p_owner_id,p_pin,v_business_code,v_property_code);
end;
$$;

-- Temporary administrator PINs are four digits; administrators may later choose 4-8 digits.
create or replace function public.start_admin_session(
  p_owner_id uuid,p_pin text,p_business_code text default 'omg',p_property_code text default 'seoul-station'
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner public.owners%rowtype;v_session public.owner_sessions%rowtype;
  v_token uuid:=gen_random_uuid();v_now timestamptz:=clock_timestamp();v_failures integer;
begin
  if p_owner_id is null or p_pin is null or p_pin!~'^[0-9]{4,8}$' then
    return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.');end if;
  select o.* into v_owner from public.owners o join public.properties p on p.id=o.property_id and p.business_id=o.business_id
  join public.businesses b on b.id=o.business_id where o.id=p_owner_id and o.active and b.code=p_business_code and p.code=p_property_code for update of o;
  if not found then return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.');end if;
  if v_owner.login_locked_until>v_now then return jsonb_build_object('ok',false,'code','locked','message','PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');end if;
  v_failures:=case when v_owner.login_locked_until is not null then 0 else v_owner.login_failures end;
  if omg_private.pin_matches(p_pin,v_owner.pin_hash) is not true then
    v_failures:=v_failures+1;update public.owners set login_failures=v_failures,login_locked_until=case when v_failures>=5 then v_now+interval '15 minutes' else null end where id=v_owner.id;
    return jsonb_build_object('ok',false,'code',case when v_failures>=5 then 'locked' else 'invalid_credentials' end,
      'message',case when v_failures>=5 then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.' else '관리자와 PIN을 확인해주세요.' end);end if;
  update public.owners set login_failures=0,login_locked_until=null where id=v_owner.id;
  insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
  values(v_owner.id,v_owner.business_id,v_owner.property_id,omg_private.token_hash(v_token),v_now+interval '12 hours') returning * into v_session;
  return omg_private.owner_session_result(v_session.id)||jsonb_build_object('access_token',v_token);
end;
$$;

revoke all on function public.get_or_create_account_property(),public.acknowledge_account_onboarding(),
  public.list_account_login_employees(),public.list_account_login_admins(),
  public.start_account_work_session(uuid,text),public.start_account_admin_session(uuid,text) from public,anon;
grant execute on function public.get_or_create_account_property(),public.acknowledge_account_onboarding(),
  public.list_account_login_employees(),public.list_account_login_admins(),
  public.start_account_work_session(uuid,text),public.start_account_admin_session(uuid,text) to authenticated;

commit;
select '계정별 숙소 연결과 신규 숙소 자동 생성 준비 완료' as result;
