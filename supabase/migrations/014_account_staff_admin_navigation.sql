-- Unified PIN login and owner-managed administrator accounts.
begin;

create or replace function public.list_login_admins(
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns table(owner_id uuid, display_name text)
language sql security definer set search_path='' as $$
  select o.id,o.display_name
  from public.owners o
  join public.properties p on p.id=o.property_id and p.business_id=o.business_id
  join public.businesses b on b.id=o.business_id
  where b.code=p_business_code and p.code=p_property_code and o.active
  order by o.created_at,o.id;
$$;

create or replace function public.start_admin_session(
  p_owner_id uuid,p_pin text,
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner public.owners%rowtype;v_session public.owner_sessions%rowtype;
  v_token uuid:=gen_random_uuid();v_now timestamptz:=clock_timestamp();v_failures integer;
begin
  if p_owner_id is null or p_pin is null or p_pin!~'^[0-9]{6,8}$' then
    return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.');
  end if;
  select o.* into v_owner from public.owners o
  join public.properties p on p.id=o.property_id and p.business_id=o.business_id
  join public.businesses b on b.id=o.business_id
  where o.id=p_owner_id and o.active and b.code=p_business_code and p.code=p_property_code
  for update of o;
  if not found then return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.'); end if;
  if v_owner.login_locked_until>v_now then
    return jsonb_build_object('ok',false,'code','locked','message','PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');
  end if;
  v_failures:=case when v_owner.login_locked_until is not null then 0 else v_owner.login_failures end;
  if omg_private.pin_matches(p_pin,v_owner.pin_hash) is not true then
    v_failures:=v_failures+1;
    update public.owners set login_failures=v_failures,
      login_locked_until=case when v_failures>=5 then v_now+interval '15 minutes' else null end
    where id=v_owner.id;
    return jsonb_build_object('ok',false,'code',case when v_failures>=5 then 'locked' else 'invalid_credentials' end,
      'message',case when v_failures>=5 then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.' else '관리자와 PIN을 확인해주세요.' end);
  end if;
  update public.owners set login_failures=0,login_locked_until=null where id=v_owner.id;
  insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
  values(v_owner.id,v_owner.business_id,v_owner.property_id,omg_private.token_hash(v_token),v_now+interval '12 hours')
  returning * into v_session;
  return omg_private.owner_session_result(v_session.id)||jsonb_build_object('access_token',v_token);
end;
$$;

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;v_can_manage boolean:=false;
  v_employees jsonb:='[]'::jsonb;v_administrators jsonb:='[]'::jsonb;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    select * into v_property from public.properties where id=v_owner_session.property_id;
    v_can_manage:=true;
  else
    select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    select * into v_employee from public.employees where id=v_session.employee_id;
    select * into v_property from public.properties where id=v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'role',e.role,
      'pin_ready',e.pin_hash is not null,'report_config',e.report_config) order by e.created_at,e.id),'[]'::jsonb)
    into v_employees from public.employees e where e.property_id=v_property.id and e.active and e.role<>'owner';
    select coalesce(jsonb_agg(jsonb_build_object('owner_id',o.id,'display_name',o.display_name,'login_id',o.login_id,
      'is_current',o.id=v_owner_session.owner_id) order by o.created_at,o.id),'[]'::jsonb)
    into v_administrators from public.owners o where o.property_id=v_property.id and o.active;
  end if;
  return jsonb_build_object('ok',true,'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
    'rooms',v_property.rooms,'room_types',v_property.room_types,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'administrators',v_administrators,'can_manage',v_can_manage);
end;
$$;

create or replace function public.save_admin_accounts(p_access_token uuid,p_administrators jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_owner_id uuid;
  v_name text;v_login_id text;v_pin text;v_pin_hash text;v_crypto_schema text;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 관리자 계정을 변경할 수 있습니다.'); end if;
  if jsonb_typeof(p_administrators)<>'array' or jsonb_array_length(p_administrators)<1 or jsonb_array_length(p_administrators)>20 then
    return jsonb_build_object('ok',false,'code','invalid_administrators','message','관리자 계정을 확인해주세요.');
  end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_administrators) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_login_id:=btrim(coalesce(v_item->>'login_id',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_login_id) not between 1 and 50
      or (v_pin<>'' and v_pin!~'^[0-9]{6,8}$') then
      return jsonb_build_object('ok',false,'code','invalid_administrator','message','관리자 계정명과 PIN(숫자 6~8자리)을 확인해주세요.');
    end if;
    begin v_owner_id:=nullif(v_item->>'owner_id','')::uuid;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_administrator','message','관리자 계정을 확인해주세요.'); end;
    if exists(select 1 from public.owners o where o.business_id=v_business_id and lower(o.login_id)=lower(v_login_id)
      and o.active and (v_owner_id is null or o.id<>v_owner_id)) then
      return jsonb_build_object('ok',false,'code','duplicate_login','message','이미 사용 중인 관리자 계정명입니다.');
    end if;
    if v_pin<>'' then
      execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;
    else v_pin_hash:=null;end if;
    if v_owner_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||' 관리자의 PIN을 입력해주세요.'); end if;
      insert into public.owners(business_id,property_id,display_name,login_id,pin_hash,active)
      values(v_business_id,v_property_id,v_name,v_login_id,v_pin_hash,true);
    else
      update public.owners set display_name=v_name,login_id=v_login_id,pin_hash=coalesce(v_pin_hash,pin_hash),
        login_failures=0,login_locked_until=null
      where id=v_owner_id and property_id=v_property_id and business_id=v_business_id and active;
      if not found then return jsonb_build_object('ok',false,'code','unknown_administrator','message','존재하지 않는 관리자 계정이 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.get_work_app_config(p_access_token);
end;
$$;

create or replace function public.delete_admin_account(p_access_token uuid,p_owner_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_current_owner_id uuid;
begin
  select s.property_id,s.owner_id into v_property_id,v_current_owner_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 삭제할 수 있습니다.'); end if;
  if p_owner_id=v_current_owner_id then return jsonb_build_object('ok',false,'code','current_account','message','현재 로그인한 관리자 계정은 삭제할 수 없습니다.'); end if;
  if (select count(*) from public.owners where property_id=v_property_id and active)<=1 then
    return jsonb_build_object('ok',false,'code','last_administrator','message','마지막 관리자 계정은 삭제할 수 없습니다.');
  end if;
  update public.owners set active=false,login_locked_until=null where id=p_owner_id and property_id=v_property_id and active;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','관리자 계정을 찾을 수 없습니다.'); end if;
  update public.owner_sessions set token_expires_at=clock_timestamp() where owner_id=p_owner_id and token_expires_at>clock_timestamp();
  return public.get_work_app_config(p_access_token);
end;
$$;

revoke all on function public.list_login_admins(text,text),public.start_admin_session(uuid,text,text,text),
  public.save_admin_accounts(uuid,jsonb),public.delete_admin_account(uuid,uuid) from public;
grant execute on function public.list_login_admins(text,text),public.start_admin_session(uuid,text,text,text) to anon,authenticated;
grant execute on function public.save_admin_accounts(uuid,jsonb),public.delete_admin_account(uuid,uuid) to anon,authenticated;

commit;
select '통합 로그인·직원/관리자 관리 준비 완료' as result;
