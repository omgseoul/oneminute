-- Store the contact and payout details edited from each employee account card.
alter table public.employees add column if not exists contact_phone text not null default '';
alter table public.employees add column if not exists bank_account text not null default '';

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname='employees_contact_phone_length') then
    alter table public.employees add constraint employees_contact_phone_length check (char_length(contact_phone)<=40);
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint where conname='employees_bank_account_length') then
    alter table public.employees add constraint employees_bank_account_length check (char_length(bank_account)<=120);
  end if;
end $$;

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'role',e.role,
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
$function$;

create or replace function public.shared_get_work_app_config(p_access_token uuid,p_property_id uuid,p_scope text)
returns jsonb language plpgsql security definer set search_path to '' as $function$
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
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'role',e.role,
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
$function$;

create or replace function public.save_employee_accounts(p_access_token uuid,p_employees jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_pin text;v_profile text;
  v_job_title text;v_contact_phone text;v_bank_account text;v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>50 then return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.'); end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    v_profile:=nullif(v_item->>'profile_image','');v_job_title:=btrim(coalesce(v_item->>'job_title',''));
    v_contact_phone:=btrim(coalesce(v_item->>'contact_phone',''));v_bank_account:=btrim(coalesce(v_item->>'bank_account',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_job_title)>60 or char_length(v_contact_phone)>40 or char_length(v_bank_account)>120 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')
      or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 정보를 확인해주세요.'); end if;
    begin v_employee_id:=nullif(v_item->>'employee_id','')::uuid;v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.'); end;
    if v_pin<>'' then execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out,profile_image,job_title,contact_phone,bank_account)
      values(v_business_id,v_property_id,v_name,v_pin_hash,'staff',true,v_clock_in,v_clock_out,v_profile,v_job_title,v_contact_phone,v_bank_account);
    else
      update public.employees set display_name=v_name,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,
        job_title=v_job_title,contact_phone=v_contact_phone,bank_account=v_bank_account,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.get_work_app_config(p_access_token);
end;
$function$;

create or replace function public.shared_save_employee_accounts(p_access_token uuid,p_property_id uuid,p_employees jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_pin text;v_profile text;
  v_job_title text;v_contact_phone text;v_bank_account text;v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;select business_id into v_business_id from public.properties where id=p_property_id;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>50 then return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.'); end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    v_profile:=nullif(v_item->>'profile_image','');v_job_title:=btrim(coalesce(v_item->>'job_title',''));
    v_contact_phone:=btrim(coalesce(v_item->>'contact_phone',''));v_bank_account:=btrim(coalesce(v_item->>'bank_account',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_job_title)>60 or char_length(v_contact_phone)>40 or char_length(v_bank_account)>120 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')
      or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 정보를 확인해주세요.'); end if;
    begin v_employee_id:=nullif(v_item->>'employee_id','')::uuid;v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.'); end;
    if v_pin<>'' then execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out,profile_image,job_title,contact_phone,bank_account)
      values(v_business_id,v_property_id,v_name,v_pin_hash,'staff',true,v_clock_in,v_clock_out,v_profile,v_job_title,v_contact_phone,v_bank_account);
    else
      update public.employees set display_name=v_name,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,
        job_title=v_job_title,contact_phone=v_contact_phone,bank_account=v_bank_account,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
end;
$function$;
