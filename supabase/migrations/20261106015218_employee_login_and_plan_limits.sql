-- Existing active accounts keep their names as IDs. Uniqueness is property-scoped.
ALTER TABLE public.employees ADD COLUMN login_id text;
UPDATE public.employees SET login_id=btrim(display_name);
ALTER TABLE public.employees ALTER COLUMN login_id SET NOT NULL;
ALTER TABLE public.employees ADD CONSTRAINT employee_login_id_valid CHECK (char_length(login_id) BETWEEN 1 AND 50 AND login_id=btrim(login_id) AND login_id !~ '[[:cntrl:]]');
CREATE UNIQUE INDEX employees_active_login_id_key ON public.employees(property_id,lower(login_id)) WHERE active AND role<>'owner';
ALTER TABLE omg_private.service_plans ADD COLUMN employee_limit integer NOT NULL DEFAULT 10 CHECK(employee_limit BETWEEN 1 AND 10000),
 ADD COLUMN room_limit integer NOT NULL DEFAULT 10 CHECK(room_limit BETWEEN 1 AND 10000);

CREATE OR REPLACE FUNCTION omg_private.guard_employee_identity_and_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_limit integer;v_count integer;v_growing boolean;
BEGIN
 NEW.login_id:=btrim(coalesce(NEW.login_id,NEW.display_name));
 IF char_length(NEW.login_id) NOT BETWEEN 1 AND 50 OR NEW.login_id ~ '[[:cntrl:]]' THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='아이디는 1~50자로 입력해주세요.';
 END IF;
 IF NOT NEW.active OR NEW.role='owner' THEN RETURN NEW; END IF;
 v_growing:=TG_OP='INSERT';
 IF TG_OP='UPDATE' THEN v_growing:=NOT OLD.active OR OLD.role='owner' OR OLD.property_id IS DISTINCT FROM NEW.property_id; END IF;
 IF v_growing THEN
  -- Serialize additions/reactivations within a property, including concurrent requests.
  PERFORM 1 FROM public.properties WHERE id=NEW.property_id FOR UPDATE;
  SELECT coalesce(sp.employee_limit,10) INTO v_limit FROM public.properties p LEFT JOIN omg_private.service_plans sp ON sp.code=p.service_plan WHERE p.id=NEW.property_id;
  SELECT count(*) INTO v_count FROM public.employees e WHERE e.property_id=NEW.property_id AND e.active AND e.role<>'owner' AND e.id IS DISTINCT FROM NEW.id;
  IF v_count>=coalesce(v_limit,10) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='요금제의 근무자 계정 한도('||coalesce(v_limit,10)||'개)를 초과했습니다.'; END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION omg_private.guard_employee_identity_and_limit() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER employee_identity_and_limit BEFORE INSERT OR UPDATE ON public.employees FOR EACH ROW EXECUTE FUNCTION omg_private.guard_employee_identity_and_limit();

CREATE OR REPLACE FUNCTION omg_private.guard_room_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_limit integer;v_old integer:=0;v_new integer;
BEGIN
 v_new:=jsonb_array_length(coalesce(NEW.rooms,'[]'));
 IF TG_OP='UPDATE' THEN v_old:=jsonb_array_length(coalesce(OLD.rooms,'[]')); END IF;
 IF v_new<=v_old THEN RETURN NEW; END IF;
 SELECT room_limit INTO v_limit FROM omg_private.service_plans WHERE code=NEW.service_plan;
 IF v_new>coalesce(v_limit,10) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='요금제의 객실 수 한도('||coalesce(v_limit,10)||'개)를 초과했습니다.'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION omg_private.guard_room_limit() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER room_plan_limit BEFORE INSERT OR UPDATE OF rooms ON public.properties FOR EACH ROW EXECUTE FUNCTION omg_private.guard_room_limit();

CREATE OR REPLACE FUNCTION public.start_account_work_session_by_login(p_login_id text,p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_employee uuid;v_result jsonb;
BEGIN
 SELECT e.id INTO v_employee FROM public.account_properties a JOIN public.employees e ON e.property_id=a.property_id AND e.business_id=a.business_id
 WHERE a.user_id=auth.uid() AND e.active AND e.role<>'owner' AND lower(e.login_id)=lower(btrim(p_login_id));
 IF v_employee IS NULL THEN RETURN jsonb_build_object('ok',false,'code','invalid_credentials','message','아이디와 PIN을 확인해주세요.'); END IF;
 v_result:=public.start_account_work_session(v_employee,p_pin);
 IF v_result->>'code'='invalid_credentials' THEN v_result:=v_result||jsonb_build_object('message','아이디와 PIN을 확인해주세요.'); END IF;
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.start_account_work_session_by_login(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_account_work_session_by_login(text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.get_work_app_config(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;v_can_manage boolean:=false;
  v_employees jsonb:='[]'::jsonb;v_administrators jsonb:='[]'::jsonb;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    select * into v_property from public.properties where id=v_owner_session.property_id;v_can_manage:=true;
  else
    select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    select * into v_employee from public.employees where id=v_session.employee_id;
    select * into v_property from public.properties where id=v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'login_id',e.login_id,'role',e.role,
      'pin_ready',e.pin_hash is not null,'job_title',e.job_title,'contact_phone',e.contact_phone,'bank_account',e.bank_account,
      'report_config',e.report_config,'profile_image',e.profile_image,
      'scheduled_clock_in',case when e.scheduled_clock_in is null then null else to_char(e.scheduled_clock_in,'HH24:MI') end,
      'scheduled_clock_out',case when e.scheduled_clock_out is null then null else to_char(e.scheduled_clock_out,'HH24:MI') end)
      order by e.created_at,e.id),'[]'::jsonb)
    into v_employees from public.employees e where e.property_id=v_property.id and e.active and e.role<>'owner';
    select coalesce(jsonb_agg(jsonb_build_object('owner_id',o.id,'display_name',o.display_name,'login_id',o.login_id,
      'profile_image',o.profile_image,'is_current',o.id=v_owner_session.owner_id) order by o.created_at,o.id),'[]'::jsonb)
    into v_administrators from public.owners o where o.property_id=v_property.id and o.active;
  end if;
  return jsonb_build_object('ok',true,'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
    'rooms',v_property.rooms,'room_types',v_property.room_types,'business_type',v_property.business_type,
    'custom_report_fields',v_property.custom_report_fields,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'administrators',v_administrators,'can_manage',v_can_manage);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_get_work_app_config(p_access_token uuid, p_property_id uuid, p_scope text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;v_can_manage boolean:=false;
  v_employees jsonb:='[]'::jsonb;v_administrators jsonb:='[]'::jsonb;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    if p_scope not in ('property_settings','account_settings') or not omg_private.can_manage_shared_property(p_access_token,p_property_id,p_scope) then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
    select * into v_property from public.properties where id=p_property_id;v_can_manage:=true;
  else
    select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    select * into v_employee from public.employees where id=v_session.employee_id;
    select * into v_property from public.properties where id=v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'login_id',e.login_id,'role',e.role,
      'pin_ready',e.pin_hash is not null,'job_title',e.job_title,'contact_phone',e.contact_phone,'bank_account',e.bank_account,
      'report_config',e.report_config,'profile_image',e.profile_image,
      'scheduled_clock_in',case when e.scheduled_clock_in is null then null else to_char(e.scheduled_clock_in,'HH24:MI') end,
      'scheduled_clock_out',case when e.scheduled_clock_out is null then null else to_char(e.scheduled_clock_out,'HH24:MI') end)
      order by e.created_at,e.id),'[]'::jsonb)
    into v_employees from public.employees e where e.property_id=v_property.id and e.active and e.role<>'owner';
    select coalesce(jsonb_agg(jsonb_build_object('owner_id',o.id,'display_name',o.display_name,'login_id',o.login_id,
      'profile_image',o.profile_image,'is_current',o.id=v_owner_session.owner_id) order by o.created_at,o.id),'[]'::jsonb)
    into v_administrators from public.owners o where o.property_id=v_property.id and o.active;
  end if;
  return jsonb_build_object('ok',true,'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
    'rooms',v_property.rooms,'room_types',v_property.room_types,'business_type',v_property.business_type,
    'custom_report_fields',v_property.custom_report_fields,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'administrators',v_administrators,'can_manage',v_can_manage);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.save_employee_accounts(p_access_token uuid, p_employees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_login_id text;v_pin text;v_profile text;
  v_job_title text;v_contact_phone text;v_bank_account text;v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>10000 then return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.'); end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    v_profile:=nullif(v_item->>'profile_image','');v_job_title:=btrim(coalesce(v_item->>'job_title',''));
    v_contact_phone:=btrim(coalesce(v_item->>'contact_phone',''));v_bank_account:=btrim(coalesce(v_item->>'bank_account',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_job_title)>60 or char_length(v_contact_phone)>40 or char_length(v_bank_account)>120 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')
      or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 정보를 확인해주세요.'); end if;
    begin v_employee_id:=nullif(v_item->>'employee_id','')::uuid;v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.'); end;
    v_login_id:=CASE WHEN v_item ? 'login_id' THEN btrim(coalesce(v_item->>'login_id',''))
      WHEN v_employee_id IS NULL THEN v_name ELSE (SELECT login_id FROM public.employees WHERE id=v_employee_id AND property_id=v_property_id) END;
    if coalesce(char_length(v_login_id),0) not between 1 and 50 then raise check_violation using message='아이디는 1~50자로 입력해주세요.';end if;
    if v_pin<>'' then execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,login_id,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out,profile_image,job_title,contact_phone,bank_account)
      values(v_business_id,v_property_id,v_name,v_login_id,v_pin_hash,'staff',true,v_clock_in,v_clock_out,v_profile,v_job_title,v_contact_phone,v_bank_account);
    else
      update public.employees set display_name=v_name,login_id=v_login_id,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,
        job_title=v_job_title,contact_phone=v_contact_phone,bank_account=v_bank_account,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.get_work_app_config(p_access_token);
exception when unique_violation then
 return jsonb_build_object('ok',false,'code','duplicate_login_id','message','동일한 아이디가 있습니다. 새로운 아이디를 입력해주세요.');
 when check_violation then return jsonb_build_object('ok',false,'code','invalid_employee','message',SQLERRM);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_employee_accounts(p_access_token uuid, p_property_id uuid, p_employees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_login_id text;v_pin text;v_profile text;
  v_job_title text;v_contact_phone text;v_bank_account text;v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;select business_id into v_business_id from public.properties where id=p_property_id;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>10000 then return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.'); end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    v_profile:=nullif(v_item->>'profile_image','');v_job_title:=btrim(coalesce(v_item->>'job_title',''));
    v_contact_phone:=btrim(coalesce(v_item->>'contact_phone',''));v_bank_account:=btrim(coalesce(v_item->>'bank_account',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_job_title)>60 or char_length(v_contact_phone)>40 or char_length(v_bank_account)>120 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')
      or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 정보를 확인해주세요.'); end if;
    begin v_employee_id:=nullif(v_item->>'employee_id','')::uuid;v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.'); end;
    v_login_id:=CASE WHEN v_item ? 'login_id' THEN btrim(coalesce(v_item->>'login_id',''))
      WHEN v_employee_id IS NULL THEN v_name ELSE (SELECT login_id FROM public.employees WHERE id=v_employee_id AND property_id=v_property_id) END;
    if coalesce(char_length(v_login_id),0) not between 1 and 50 then raise check_violation using message='아이디는 1~50자로 입력해주세요.';end if;
    if v_pin<>'' then execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,login_id,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out,profile_image,job_title,contact_phone,bank_account)
      values(v_business_id,v_property_id,v_name,v_login_id,v_pin_hash,'staff',true,v_clock_in,v_clock_out,v_profile,v_job_title,v_contact_phone,v_bank_account);
    else
      update public.employees set display_name=v_name,login_id=v_login_id,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,
        job_title=v_job_title,contact_phone=v_contact_phone,bank_account=v_bank_account,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
exception when unique_violation then
 return jsonb_build_object('ok',false,'code','duplicate_login_id','message','동일한 아이디가 있습니다. 새로운 아이디를 입력해주세요.');
 when check_violation then return jsonb_build_object('ok',false,'code','invalid_employee','message',SQLERRM);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.platform_operations(p_action text DEFAULT 'get'::text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   insert into omg_private.service_plans(code,name,monthly_price,storage_limit_bytes,employee_limit,room_limit)
   values(plan->>'code',left(btrim(plan->>'name'),40),nullif(plan->>'monthly_price','')::integer,(plan->>'storage_limit_bytes')::bigint,coalesce((plan->>'employee_limit')::integer,(select employee_limit from omg_private.service_plans where code=plan->>'code'),10),coalesce((plan->>'room_limit')::integer,(select room_limit from omg_private.service_plans where code=plan->>'code'),10))
   on conflict(code) do update set name=excluded.name,monthly_price=excluded.monthly_price,storage_limit_bytes=excluded.storage_limit_bytes,employee_limit=excluded.employee_limit,room_limit=excluded.room_limit;
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
end$function$
;
