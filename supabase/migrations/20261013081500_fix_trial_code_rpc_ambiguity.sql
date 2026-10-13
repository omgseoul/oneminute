-- Fix PL/pgSQL record/SQL alias ambiguity in the operator code list.
create or replace function public.platform_trial_codes(p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare n int;value text;days int;lim bigint;expiry timestamptz;items jsonb;c omg_private.trial_codes%rowtype;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='create' then
  n:=coalesce((p_data->>'count')::int,1);if n not between 1 and 100 then raise exception '한 번에 1~100개를 생성할 수 있습니다.';end if;
  select coalesce((p_data->>'trial_days')::int,trial_days),coalesce((p_data->>'storage_limit_bytes')::bigint,storage_limit_bytes) into days,lim from omg_private.service_policy where id;
  expiry:=nullif(p_data->>'expires_at','')::timestamptz;
  if expiry is not null and expiry<=now() then raise exception '코드 만료일은 미래로 설정해주세요.';end if;
  if btrim(coalesce(p_data->>'code',''))<>'' and n<>1 then raise exception '직접 지정한 코드는 한 개씩 생성해주세요.';end if;
  for i in 1..n loop
   value:=omg_private.normalize_trial_code(nullif(btrim(p_data->>'code'),''));
   if value='' then value:='OMS'||upper(replace(gen_random_uuid()::text,'-',''));end if;
   insert into omg_private.trial_codes(code,trial_days,storage_limit_bytes,expires_at,note,created_by) values(value,days,lim,expiry,btrim(coalesce(p_data->>'note','')),auth.uid());
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_codes_created',jsonb_build_object('count',n,'trial_days',days,'storage_limit_bytes',lim));
 elsif p_action='revoke' then
  update omg_private.trial_codes set revoked_at=now() where id=(p_data->>'id')::uuid and used_at is null and revoked_at is null;
  if not found then return jsonb_build_object('ok',false,'message','미사용 코드만 사용 중지할 수 있습니다.');end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_code_revoked',jsonb_build_object('id',p_data->>'id'));
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into items from(
  select tc.id,tc.code,tc.trial_days,tc.storage_limit_bytes,tc.expires_at,tc.note,tc.created_at,tc.used_at,tc.used_email,tc.registration_name,tc.registration_property_name,tc.property_id,p.name property_name,
   case when tc.used_at is not null then 'used' when tc.revoked_at is not null then 'revoked' when tc.expires_at<=now() then 'expired' else 'unused' end status
  from omg_private.trial_codes tc left join public.properties p on p.id=tc.property_id
 )x;
 return jsonb_build_object('ok',true,'codes',items);
end$$;
