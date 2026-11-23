create table omg_private.owner_sensitive_passwords (
 owner_id uuid primary key references public.owners(id) on delete cascade,
 password_hash text not null,
 failures integer not null default 0,
 locked_until timestamptz
);
alter table omg_private.owner_sensitive_passwords enable row level security;
revoke all on omg_private.owner_sensitive_passwords from public, anon, authenticated;

create function omg_private.owner_sensitive_password(p_access_token uuid,p_action text,p_password text,p_login_pin text,p_new_password text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_owner public.owners%rowtype;
 v_secret omg_private.owner_sensitive_passwords%rowtype;
 v_now timestamptz;
 v_schema text;
 v_hash text;
begin
 select o.* into v_owner from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active
 for update of o;
 if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.');end if;
 select * into v_secret from omg_private.owner_sensitive_passwords where owner_id=v_owner.id;
 if p_action='status' then return jsonb_build_object('ok',true,'configured',v_secret.owner_id is not null);end if;
 v_now:=clock_timestamp();
 if v_secret.locked_until>v_now then
  return jsonb_build_object('ok',false,'message','입력 시도가 잠겼습니다. 15분 후 다시 시도해주세요.');
 end if;
 if p_action='verify' and v_secret.owner_id is null then
  return jsonb_build_object('ok',false,'message','관리자 계정에서 2차 비밀번호를 먼저 설정해주세요.');
 end if;
 if p_action='set' then
  if p_new_password is null or char_length(p_new_password)<8 or octet_length(p_new_password)>72 or btrim(p_new_password)='' then
   return jsonb_build_object('ok',false,'message','2차 비밀번호는 8자 이상, 72바이트 이하로 입력해주세요.');
  end if;
  if v_owner.login_locked_until>v_now then
   return jsonb_build_object('ok',false,'message','로그인 PIN 입력이 잠겼습니다. 15분 후 다시 시도해주세요.');
  end if;
  if p_login_pin is null or p_login_pin !~ '^[0-9]{4,8}$' or omg_private.pin_matches(p_login_pin,v_owner.pin_hash) is not true then
   v_owner.login_failures:=case when v_owner.login_locked_until is not null then 1 else v_owner.login_failures+1 end;
   update public.owners set login_failures=v_owner.login_failures,
    login_locked_until=case when v_owner.login_failures>=5 then v_now+interval '15 minutes' end where id=v_owner.id;
   return jsonb_build_object('ok',false,'message','로그인 PIN을 확인해주세요.');
  end if;
  update public.owners set login_failures=0,login_locked_until=null where id=v_owner.id;
  if p_new_password=p_login_pin then
   return jsonb_build_object('ok',false,'message','로그인 PIN과 다른 비밀번호를 입력해주세요.');
  end if;
 end if;
 if v_secret.owner_id is not null and (p_password is null or octet_length(p_password)>72
    or omg_private.pin_matches(p_password,v_secret.password_hash) is not true) then
  v_secret.failures:=case when v_secret.locked_until is not null then 1 else v_secret.failures+1 end;
  update omg_private.owner_sensitive_passwords set failures=v_secret.failures,
   locked_until=case when v_secret.failures>=5 then v_now+interval '15 minutes' end where owner_id=v_owner.id;
  return jsonb_build_object('ok',false,'message','2차 비밀번호를 확인해주세요.');
 end if;
 if p_action='set' then
  select n.nspname into strict v_schema from pg_catalog.pg_extension e
  join pg_catalog.pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto';
  execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_schema,v_schema) into v_hash using p_new_password;
  insert into omg_private.owner_sensitive_passwords(owner_id,password_hash) values(v_owner.id,v_hash)
  on conflict(owner_id) do update set password_hash=excluded.password_hash,failures=0,locked_until=null;
 else
  update omg_private.owner_sensitive_passwords set failures=0,locked_until=null
  where owner_id=v_owner.id and (failures<>0 or locked_until is not null);
 end if;
 return jsonb_build_object('ok',true,'configured',true);
end $$;

create function public.manage_owner_sensitive_password(p_access_token uuid,p_login_pin text default null,p_current_password text default null,p_new_password text default null)
returns jsonb language sql security definer set search_path='' as $$
 select omg_private.owner_sensitive_password(p_access_token,case when p_new_password is null then 'status' else 'set' end,p_current_password,p_login_pin,p_new_password)
$$;
create function public.verify_owner_sensitive_password(p_access_token uuid,p_password text)
returns jsonb language sql security definer set search_path='' as $$
 select omg_private.owner_sensitive_password(p_access_token,'verify',p_password,null,null)
$$;
revoke all on function omg_private.owner_sensitive_password(uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.manage_owner_sensitive_password(uuid,text,text,text) from public;
grant execute on function public.manage_owner_sensitive_password(uuid,text,text,text) to anon,authenticated;
revoke all on function public.verify_owner_sensitive_password(uuid,text) from public,anon,authenticated;
grant execute on function public.verify_owner_sensitive_password(uuid,text) to service_role;
