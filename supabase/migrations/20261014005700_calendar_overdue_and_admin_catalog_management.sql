-- Prioritize overdue open To dos on today and let operators safely manage plans and trial codes.
-- Keep a single default plan; abort rather than changing an in-use customer plan.
do $$
begin
 if exists(
  select 1 from public.properties p
  join omg_private.service_plans sp on sp.code=p.service_plan
  where sp.code<>'basic'
 ) then
  raise exception '기본 요금제가 아닌 요금제를 쓰는 고객이 있어 기본 요금제 정리를 중단했습니다.';
 end if;
 delete from omg_private.service_plans where code<>'basic';
end
$$;

create or replace function public.platform_operations(p_action text default 'get',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare prop uuid;c omg_private.service_policy%rowtype;old jsonb;result jsonb;plan jsonb;name text;status text;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then
  return jsonb_build_object('ok',false,'code','platform_admin_required','message','OMS 운영자 권한이 필요합니다.');
 end if;
 if p_action='policy' then
  if jsonb_typeof(p_data->'plans') is distinct from 'array' then
   raise exception '요금제 목록을 확인해주세요.';
  end if;
  if jsonb_array_length(p_data->'plans')=0 then
   raise exception '요금제는 최소 1개 있어야 합니다.';
  end if;
  if exists(
   select 1 from omg_private.service_plans sp
   where not exists(select 1 from jsonb_array_elements(p_data->'plans') as plans(value) where value->>'code'=sp.code)
    and exists(select 1 from public.properties customer where customer.service_plan=sp.code)
  ) then
   raise exception '고객이 사용 중인 요금제는 삭제할 수 없습니다. 먼저 고객의 요금제를 변경해주세요.';
  end if;
  select to_jsonb(x) into old from omg_private.service_policy x where id;
  update omg_private.service_policy set trial_days=(p_data->>'trial_days')::int,reminder_days=(p_data->>'reminder_days')::int,grace_days=(p_data->>'grace_days')::int,
   storage_limit_bytes=(p_data->>'storage_limit_bytes')::bigint,storage_warning_bytes=(p_data->>'storage_warning_bytes')::bigint,
   end_action=p_data->>'end_action',storage_action=p_data->>'storage_action',support_contact=btrim(coalesce(p_data->>'support_contact','')),updated_at=now() where id;
  for plan in select value from jsonb_array_elements(p_data->'plans') as plans(value) loop
   insert into omg_private.service_plans(code,name,monthly_price,storage_limit_bytes)
   values(plan->>'code',left(btrim(plan->>'name'),40),nullif(plan->>'monthly_price','')::integer,(plan->>'storage_limit_bytes')::bigint)
   on conflict(code) do update set name=excluded.name,monthly_price=excluded.monthly_price,storage_limit_bytes=excluded.storage_limit_bytes;
   if not found or btrim(plan->>'name')='' then raise exception '요금제 이름과 용량을 확인해주세요.';end if;
  end loop;
  delete from omg_private.service_plans sp
  where not exists(select 1 from jsonb_array_elements(p_data->'plans') as plans(value) where value->>'code'=sp.code);
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'service_policy_updated',jsonb_build_object('before',old,'after',p_data));
 elsif p_action='customer' then
  prop:=(p_data->>'property_id')::uuid;select service_status into status from public.properties where id=prop;
  if status is null then return jsonb_build_object('ok',false,'message','고객을 찾을 수 없습니다.');end if;
  if not exists(select 1 from omg_private.service_plans where code=p_data->>'service_plan') then raise exception '요금제를 확인해주세요.';end if;
  select to_jsonb(p) into old from public.properties p where id=prop;
  result:=public.update_platform_property(prop,coalesce(p_data->>'service_status',status),coalesce(p_data->>'operator_note',''));
  if not(result->>'ok')::boolean then return result;end if;
  update public.properties set service_plan=p_data->>'service_plan',billing_exempt=coalesce((p_data->>'billing_exempt')::boolean,false),
   trial_ends_at=nullif(p_data->>'trial_ends_at','')::timestamptz,subscription_ends_at=nullif(p_data->>'subscription_ends_at','')::timestamptz,
   service_storage_limit=nullif(p_data->>'storage_limit_bytes','')::bigint,service_storage_warning=nullif(p_data->>'storage_warning_bytes','')::bigint where id=prop;
  if exists(select 1 from public.properties where id=prop and (service_storage_limit<1048576 or service_storage_warning<1 or service_storage_warning>service_storage_limit)) then raise exception '고객별 용량과 경고 기준을 확인해주세요.';end if;
  insert into public.platform_audit_logs(operator_user_id,property_id,action,detail) values(auth.uid(),prop,'customer_service_updated',jsonb_build_object('before',jsonb_build_object('plan',old->'service_plan','trial_ends_at',old->'trial_ends_at','subscription_ends_at',old->'subscription_ends_at','billing_exempt',old->'billing_exempt'),'after',p_data));
  perform omg_private.emit_system_notice(prop,'service_updated',gen_random_uuid()::text);
 elsif p_action not in('get','usage') then raise exception '지원하지 않는 요청입니다.';
 end if;
 result:=public.get_platform_dashboard();
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 perform omg_private.refresh_service_notices();
 select coalesce(jsonb_agg((x.value)||jsonb_build_object('trial_code',(select code from omg_private.trial_codes where property_id=p.id),'service_plan',p.service_plan,'billing_exempt',p.billing_exempt,'subscription_ends_at',p.subscription_ends_at,'storage_limit_override',p.service_storage_limit,'storage_warning_override',p.service_storage_warning,'service',coalesce(n.state,omg_private.property_service_state(p.id))) order by p.management_number),'[]'::jsonb) into plan
 from jsonb_array_elements(result->'properties')x(value) join public.properties p on p.id=(x.value->>'property_id')::uuid left join omg_private.service_notices n on n.property_id=p.id;
 return result||jsonb_build_object('properties',plan,'policy',old,'plans',(select jsonb_agg(to_jsonb(x) order by code) from omg_private.service_plans x),'last_checked_at',(select max(checked_at) from omg_private.service_notices),'payment_connected',false);
end$$;
revoke all on function public.platform_operations(text,jsonb) from public,anon;
grant execute on function public.platform_operations(text,jsonb) to authenticated;

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
   if value='' then loop value:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));exit when not exists(select 1 from omg_private.trial_codes as existing_code where existing_code.code=value);end loop;elsif value !~ '^[A-Z0-9]{8}$' then raise exception '체험코드는 영문 또는 숫자 8자리로 입력해주세요.';end if;
   insert into omg_private.trial_codes(code,trial_days,storage_limit_bytes,expires_at,note,created_by) values(value,days,lim,expiry,btrim(coalesce(p_data->>'note','')),auth.uid());
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_codes_created',jsonb_build_object('count',n,'trial_days',days,'storage_limit_bytes',lim));
 elsif p_action='revoke' then
  update omg_private.trial_codes set revoked_at=now() where id=(p_data->>'id')::uuid and used_at is null and revoked_at is null;
  if not found then return jsonb_build_object('ok',false,'message','미사용 코드만 사용 중지할 수 있습니다.');end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_code_revoked',jsonb_build_object('id',p_data->>'id'));
 elsif p_action='delete' then
  select * into c from omg_private.trial_codes where id=(p_data->>'id')::uuid for update;
  if not found then return jsonb_build_object('ok',false,'message','체험코드를 찾을 수 없습니다.');end if;
  if c.used_at is not null then return jsonb_build_object('ok',false,'message','가입 이력 보존을 위해 사용 완료 코드는 삭제할 수 없습니다.');end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_code_deleted',jsonb_build_object('id',c.id,'code',c.code,'status',case when c.revoked_at is not null then 'revoked' when c.expires_at<=now() then 'expired' else 'unused' end));
  delete from omg_private.trial_codes where id=c.id and used_at is null;
  if not found then return jsonb_build_object('ok',false,'message','체험코드를 삭제하지 못했습니다. 다시 확인해주세요.');end if;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into items from(
  select tc.id,tc.code,tc.trial_days,tc.storage_limit_bytes,tc.expires_at,tc.note,tc.created_at,tc.used_at,tc.used_email,tc.registration_name,tc.registration_property_name,tc.property_id,p.name property_name,
   case when tc.used_at is not null then 'used' when tc.revoked_at is not null then 'revoked' when tc.expires_at<=now() then 'expired' else 'unused' end status
  from omg_private.trial_codes tc left join public.properties p on p.id=tc.property_id
 )x;
 return jsonb_build_object('ok',true,'codes',items);
end$$;
revoke all on function public.platform_trial_codes(text,jsonb) from public,anon;
grant execute on function public.platform_trial_codes(text,jsonb) to authenticated;

create or replace function public.list_overdue_calendar_tasks(p_access_token uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_employee_id uuid;v_owner boolean:=false;v_properties uuid[];v_tasks jsonb;
begin
 select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if found then v_owner:=true;
 else
  select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 end if;
 if v_owner then
  v_properties:=coalesce(nullif(p_property_ids,array[]::uuid[]),array[v_property_id]);
  if cardinality(v_properties)>20 or exists(select 1 from unnest(v_properties) requested(id) where requested.id<>v_property_id and not omg_private.can_manage_shared_property(p_access_token,requested.id,'missions')) then
   return jsonb_build_object('ok',false,'message','숙소 권한을 확인해주세요.');
  end if;
 else v_properties:=array[v_property_id];
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids) order by m.due_at,m.created_at),'[]'::jsonb)
 into v_tasks
 from public.missions m join public.properties p on p.id=m.property_id
 where m.property_id=any(v_properties) and m.active and m.creator_type='owner' and m.due_at<clock_timestamp()
  and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text);
 return jsonb_build_object('ok',true,'tasks',v_tasks);
end$$;
revoke all on function public.list_overdue_calendar_tasks(uuid,uuid[]) from public;
grant execute on function public.list_overdue_calendar_tasks(uuid,uuid[]) to anon,authenticated,service_role;

