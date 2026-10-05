-- Five share scopes and reminders for assigned calendars and To do items.
ALTER TABLE public.property_share_requests DROP CONSTRAINT property_share_requests_permissions_count_check;
ALTER TABLE public.property_share_requests ADD CONSTRAINT property_share_requests_permissions_count_check CHECK(cardinality(requested_permissions) BETWEEN 1 AND 5);
ALTER TABLE public.property_share_requests DROP CONSTRAINT property_share_requests_permissions_values_check;
ALTER TABLE public.property_share_requests ADD CONSTRAINT property_share_requests_permissions_values_check CHECK(requested_permissions <@ ARRAY['attendance','missions','messages','property_settings','account_settings']::text[]);
CREATE OR REPLACE FUNCTION public.request_property_share(p_access_token uuid, p_target_management_number bigint, p_permissions text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_session public.owner_sessions%rowtype;v_source public.properties%rowtype;v_target public.properties%rowtype;
  v_permissions text[];v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유를 요청할 수 있습니다.'); end if;
  select array_agg(distinct x order by x) into v_permissions from unnest(coalesce(p_permissions,'{}'::text[])) x
  where x=any(array['attendance','missions','messages','property_settings','account_settings']);
  if coalesce(cardinality(v_permissions),0)=0 or cardinality(v_permissions)<>cardinality(p_permissions) then
    return jsonb_build_object('ok',false,'code','permission_required','message','공유받을 항목을 한 개 이상 선택해주세요.');
  end if;
  select * into v_source from public.properties where id=v_session.property_id;
  select * into v_target from public.properties where management_number=p_target_management_number and id<>v_source.id;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','해당 Property ID의 지점을 찾을 수 없습니다.'); end if;
  insert into public.property_share_requests(requester_property_id,target_property_id,requester_owner_id,requested_permissions,status,requested_at,approved_at,approved_by)
  values(v_source.id,v_target.id,v_session.owner_id,v_permissions,'pending',clock_timestamp(),null,null)
  on conflict(requester_property_id,target_property_id) do update set requester_owner_id=excluded.requester_owner_id,
    requested_permissions=excluded.requested_permissions,status='pending',requested_at=clock_timestamp(),approved_at=null,approved_by=null
  returning id into v_request_id;
  v_message:=format(E'Property 공유 요청\n요청 지점: %s (Property ID %s)\n요청 항목: %s',v_source.name,v_source.management_number,
    array_to_string(array(select case x when 'attendance' then '근태관리' when 'missions' then 'To do' when 'messages' then '메세지' when 'property_settings' then '숙소설정' when 'account_settings' then '계정 설정' end from unnest(v_permissions)x),', '));
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,priority,message_type,property_share_request_id)
  values(v_source.business_id,v_source.id,'owner',v_session.owner_id,v_message,'normal','property_share_approval',v_request_id)
  returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.property_id=v_target.id and o.active;
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending');
end;
$function$
;
CREATE OR REPLACE FUNCTION omg_private.can_manage_shared_property(p_token uuid,p_property uuid,p_scope text) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_token) AND s.token_expires_at>clock_timestamp() AND o.active
 AND (s.property_id=p_property OR EXISTS(SELECT 1 FROM public.property_share_requests r WHERE r.requester_property_id=s.property_id AND r.target_property_id=p_property AND r.status='approved' AND p_scope=ANY(r.requested_permissions)))) $$;
REVOKE ALL ON FUNCTION omg_private.can_manage_shared_property(uuid,uuid,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION public.shared_get_work_app_config(p_access_token uuid,p_property_id uuid,p_scope text)
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
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'role',e.role,
      'pin_ready',e.pin_hash is not null,'job_title',e.job_title,'report_config',e.report_config,'profile_image',e.profile_image,
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
CREATE OR REPLACE FUNCTION public.shared_save_property_settings(p_access_token uuid,p_property_id uuid, p_property_name text, p_rooms jsonb, p_employee_configs jsonb, p_room_types jsonb, p_business_type text, p_custom_report_fields jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_property_id uuid;v_name text:=btrim(coalesce(p_property_name,''));v_rooms jsonb;v_room_types jsonb;
  v_pair record;v_employee_id uuid;v_custom_keys text[];
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 설정을 변경할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  if char_length(v_name) not between 1 and 80 then return jsonb_build_object('ok',false,'code','invalid_name','message','Property 이름은 1~80자로 입력해주세요.'); end if;
  if p_business_type is not null and p_business_type<>all(array['lodging','general','other']) then
    return jsonb_build_object('ok',false,'code','invalid_business_type','message','사업장 유형을 확인해주세요.');
  end if;
  if omg_private.custom_report_fields_are_valid(p_custom_report_fields) is not true then
    return jsonb_build_object('ok',false,'code','invalid_custom_fields','message','직접 만든 보고 항목을 확인해주세요.');
  end if;
  select coalesce(array_agg(value->>'key'),'{}'::text[]) into v_custom_keys from jsonb_array_elements(p_custom_report_fields);
  if p_business_type='lodging' then
    if omg_private.room_types_are_valid(p_room_types) is not true then
      return jsonb_build_object('ok',false,'code','invalid_room_types','message','객실 타입과 객실번호를 확인해주세요. 같은 객실번호는 한 번만 입력할 수 있습니다.');
    end if;
    select jsonb_agg(jsonb_build_object('name',btrim(group_item.value->>'name'),'rooms',
      (select jsonb_agg(btrim(room.value) order by room.position) from jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position))) order by group_item.position)
    into v_room_types from jsonb_array_elements(p_room_types) with ordinality group_item(value,position);
    select jsonb_agg(room.value order by room.group_position,room.room_position) into v_rooms from (
      select btrim(room.value) value,group_item.position group_position,room.position room_position
      from jsonb_array_elements(v_room_types) with ordinality group_item(value,position),
        jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)
    ) room;
  end if;
  if jsonb_typeof(p_employee_configs)<>'object' then return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.'); end if;
  for v_pair in select * from jsonb_each(p_employee_configs) loop
    begin v_employee_id:=v_pair.key::uuid; exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.'); end;
    if omg_private.report_config_is_valid(v_pair.value) is not true
      or exists(select 1 from jsonb_array_elements_text((v_pair.value->'clock_in')||(v_pair.value->'clock_out')) item(value)
        where item.value like 'custom_%' and item.value<>all(v_custom_keys)) then
      return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.');
    end if;
    if not exists(select 1 from public.employees where id=v_employee_id and property_id=v_property_id and active) then
      return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 직원이 포함되어 있습니다.');
    end if;
  end loop;
  for v_pair in select * from jsonb_each(p_employee_configs) loop
    update public.employees set report_config=v_pair.value where id=v_pair.key::uuid and property_id=v_property_id and active;
  end loop;
  update public.properties set name=v_name,business_type=p_business_type,custom_report_fields=p_custom_report_fields,
    rooms=case when p_business_type='lodging' then v_rooms else rooms end,
    room_types=case when p_business_type='lodging' then v_room_types else room_types end
  where id=v_property_id;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'property_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_property_notice(p_access_token uuid,p_property_id uuid, p_notice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_notice text:=btrim(coalesce(p_notice,''));
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공지사항을 변경할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  if char_length(v_notice)>2000 then return jsonb_build_object('ok',false,'code','invalid_notice','message','공지사항은 2,000자 이내로 입력해주세요.'); end if;
  update public.properties set notice=v_notice where id=v_property_id;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'property_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_employee_accounts(p_access_token uuid,p_property_id uuid, p_employees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_pin text;v_profile text;
  v_job_title text;v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select business_id into v_business_id from public.properties where id=p_property_id;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>50 then
    return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.');
  end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    v_profile:=nullif(v_item->>'profile_image','');v_job_title:=btrim(coalesce(v_item->>'job_title',''));
    if char_length(v_name) not between 1 and 50 or char_length(v_job_title)>60 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')
      or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then
      return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 이름, PIN 또는 프로필 사진을 확인해주세요.');
    end if;
    begin
      v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
      v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;
      v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.');
    end;
    if v_pin<>'' then
      execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;
    else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out,profile_image,job_title)
      values(v_business_id,v_property_id,v_name,v_pin_hash,'staff',true,v_clock_in,v_clock_out,v_profile,v_job_title);
    else
      update public.employees set display_name=v_name,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,
        scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,job_title=v_job_title,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_admin_accounts(p_access_token uuid,p_property_id uuid, p_administrators jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_owner_id uuid;
  v_name text;v_login_id text;v_pin text;v_pin_hash text;v_crypto_schema text;v_profile text;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 관리자 계정을 변경할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select business_id into v_business_id from public.properties where id=p_property_id;
  if jsonb_typeof(p_administrators)<>'array' or jsonb_array_length(p_administrators)<1 or jsonb_array_length(p_administrators)>20 then
    return jsonb_build_object('ok',false,'code','invalid_administrators','message','관리자 계정을 확인해주세요.');
  end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_administrators) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_login_id:=btrim(coalesce(v_item->>'login_id',v_name));
    v_pin:=btrim(coalesce(v_item->>'pin',''));v_profile:=nullif(v_item->>'profile_image','');
    if char_length(v_name) not between 1 and 50 or char_length(v_login_id) not between 1 and 50
      or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$')or(v_profile is not null and(v_profile not like 'data:image/%' or char_length(v_profile)>400000)) then
      return jsonb_build_object('ok',false,'code','invalid_administrator','message','관리자 이름, PIN 또는 프로필 사진을 확인해주세요.');
    end if;
    begin v_owner_id:=nullif(v_item->>'owner_id','')::uuid;
    exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_administrator','message','관리자 계정을 확인해주세요.');end;
    if exists(select 1 from public.owners o where o.business_id=v_business_id and lower(o.login_id)=lower(v_login_id)
      and o.active and(v_owner_id is null or o.id<>v_owner_id)) then
      return jsonb_build_object('ok',false,'code','duplicate_login_id','message',v_login_id||' 관리자 계정명이 이미 사용 중입니다.');
    end if;
    if v_pin<>'' then execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;
    else v_pin_hash:=null;end if;
    if v_owner_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.owners(business_id,property_id,display_name,login_id,pin_hash,active,profile_image)
      values(v_business_id,v_property_id,v_name,v_login_id,v_pin_hash,true,v_profile);
    else
      update public.owners set display_name=v_name,login_id=v_login_id,pin_hash=coalesce(v_pin_hash,pin_hash),profile_image=v_profile,
        login_failures=0,login_locked_until=null where id=v_owner_id and property_id=v_property_id and business_id=v_business_id and active;
      if not found then return jsonb_build_object('ok',false,'code','unknown_administrator','message','존재하지 않는 관리자 계정이 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_delete_employee_account(p_access_token uuid,p_property_id uuid, p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 삭제할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  update public.employees set active=false,login_locked_until=null
  where id=p_employee_id and property_id=v_property_id and active and role<>'owner';
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','삭제할 근무자를 찾을 수 없습니다.'); end if;
  update public.work_sessions set token_expires_at=clock_timestamp()
  where employee_id=p_employee_id and token_expires_at>clock_timestamp();
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_delete_admin_account(p_access_token uuid,p_property_id uuid, p_owner_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_current_owner_id uuid;
begin
  select s.property_id,s.owner_id into v_property_id,v_current_owner_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 삭제할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  if p_owner_id=v_current_owner_id then return jsonb_build_object('ok',false,'code','current_account','message','현재 로그인한 관리자 계정은 삭제할 수 없습니다.'); end if;
  if (select count(*) from public.owners where property_id=v_property_id and active)<=1 then
    return jsonb_build_object('ok',false,'code','last_administrator','message','마지막 관리자 계정은 삭제할 수 없습니다.');
  end if;
  update public.owners set active=false,login_locked_until=null where id=p_owner_id and property_id=v_property_id and active;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','관리자 계정을 찾을 수 없습니다.'); end if;
  update public.owner_sessions set token_expires_at=clock_timestamp() where owner_id=p_owner_id and token_expires_at>clock_timestamp();
  return public.shared_get_work_app_config(p_access_token,p_property_id,'account_settings');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_list_employee_attendance_settings(p_access_token uuid,p_property_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 설정을 볼 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'lateness_threshold_minutes',e.lateness_threshold_minutes)
    order by e.created_at,e.id),'[]'::jsonb) into v_items
  from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
  return jsonb_build_object('ok',true,'settings',v_items);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_employee_attendance_settings(p_access_token uuid,p_property_id uuid, p_employees jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_item jsonb;v_employee_id uuid;v_minutes integer;v_name text;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 설정을 저장할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  if jsonb_typeof(p_employees)<>'array' then return jsonb_build_object('ok',false,'code','invalid_settings','message','지각기준을 확인해주세요.'); end if;
  for v_item in select value from jsonb_array_elements(p_employees) loop
    begin
      v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
      v_minutes:=nullif(v_item->>'lateness_threshold_minutes','')::integer;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_settings','message','지각기준은 0~720분으로 입력해주세요.');
    end;
    v_name:=btrim(coalesce(v_item->>'display_name',''));
    if v_employee_id is null and v_name<>'' then
      select e.id into v_employee_id from public.employees e where e.property_id=v_property_id and e.active
        and e.role<>'owner' and e.display_name=v_name order by e.created_at desc limit 1;
    end if;
    if v_employee_id is not null then
      if v_minutes is not null and v_minutes not between 0 and 720 then
        return jsonb_build_object('ok',false,'code','invalid_settings','message','지각기준은 0~720분으로 입력해주세요.');
      end if;
      update public.employees set lateness_threshold_minutes=v_minutes
      where id=v_employee_id and property_id=v_property_id and active and role<>'owner';
    end if;
  end loop;
  return public.shared_list_employee_attendance_settings(p_access_token,p_property_id);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_list_attendance_warning_rules(p_access_token uuid,p_property_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_rules jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select coalesce(jsonb_agg(jsonb_build_object('rule_id',r.id,'employee_id',r.employee_id,'employee_ids',to_jsonb(r.target_employee_ids),'target_all',r.target_all,'event_type',r.event_type,
    'comparison',r.comparison,'threshold_minutes',r.threshold_minutes,'message',r.message,'active',r.active)
    order by r.created_at,r.id),'[]'::jsonb) into v_rules
  from public.attendance_warning_rules r where r.property_id=v_property_id and r.active;
  return jsonb_build_object('ok',true,'rules',v_rules);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.shared_save_attendance_warning_rules(p_access_token uuid,p_property_id uuid, p_rules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_business_id uuid;v_property_id uuid;v_item jsonb;v_rule_id uuid;v_ids uuid[];v_all boolean;
  v_event text;v_comparison text;v_minutes integer;v_message text;v_active boolean;v_keep uuid[]:='{}';
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select business_id into v_business_id from public.properties where id=p_property_id;
  if p_rules is null or jsonb_typeof(p_rules)<>'array' or jsonb_array_length(p_rules)>50 then
    raise exception '근무시간 워닝 조건을 확인해주세요.'; end if;
  for v_item in select value from jsonb_array_elements(p_rules) loop
    v_rule_id:=nullif(v_item->>'rule_id','')::uuid;
    v_all:=coalesce((v_item->>'target_all')::boolean,false);
    if v_all then v_ids:='{}';
    elsif v_item ? 'employee_ids' then
      if jsonb_typeof(v_item->'employee_ids')<>'array' then raise exception '근로자를 선택해주세요.'; end if;
      select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_ids from jsonb_array_elements_text(v_item->'employee_ids');
    else v_ids:=array_remove(array[nullif(v_item->>'employee_id','')::uuid],null); end if;
    v_event:=coalesce(v_item->>'event_type','');v_comparison:=coalesce(v_item->>'comparison','');
    v_minutes:=coalesce((v_item->>'threshold_minutes')::integer,0);
    v_message:=btrim(coalesce(v_item->>'message',''));v_active:=coalesce((v_item->>'active')::boolean,true);
    if cardinality(v_ids)>50
      or exists(select 1 from unnest(v_ids) x(id) where not exists(select 1 from public.employees e where e.id=x.id and e.property_id=v_property_id and e.active and e.role<>'owner'))
      or v_event not in('clock_in','clock_out','work_duration') or v_comparison not in('late','early','both')
      or v_minutes not between 0 and 720 or char_length(v_message) not between 1 and 1000 then
      raise exception '대상·조건·시간·근태관리 메세지 내용을 확인해주세요.'; end if;
    if v_rule_id is null then
      insert into public.attendance_warning_rules(business_id,property_id,employee_id,target_employee_ids,target_all,event_type,comparison,threshold_minutes,message,active)
      values(v_business_id,v_property_id,null,v_ids,v_all,v_event,v_comparison,v_minutes,v_message,v_active) returning id into v_rule_id;
    else
      update public.attendance_warning_rules set employee_id=null,target_employee_ids=v_ids,target_all=v_all,event_type=v_event,comparison=v_comparison,
        threshold_minutes=v_minutes,message=v_message,active=v_active,updated_at=clock_timestamp()
        where id=v_rule_id and property_id=v_property_id;
      if not found then raise exception '수정할 워닝 조건을 찾지 못했습니다.'; end if;
    end if;
    v_keep:=array_append(v_keep,v_rule_id);
  end loop;
  -- Archive omitted rules to retain delivery history.
  update public.attendance_warning_rules set active=false where property_id=v_property_id and not(id=any(v_keep));
  return public.shared_list_attendance_warning_rules(p_access_token,p_property_id);
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok',false,'code','invalid_rule','message',case when SQLSTATE='P0001' then SQLERRM else '근무시간 워닝 입력값을 확인해주세요.' end);
end;
$function$
;
REVOKE ALL ON FUNCTION public.shared_get_work_app_config(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_get_work_app_config(uuid,uuid,text) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_property_settings(uuid,uuid,text,jsonb,jsonb,jsonb,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_property_settings(uuid,uuid,text,jsonb,jsonb,jsonb,text,jsonb) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_property_notice(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_property_notice(uuid,uuid,text) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_employee_accounts(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_employee_accounts(uuid,uuid,jsonb) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_admin_accounts(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_admin_accounts(uuid,uuid,jsonb) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_delete_employee_account(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_delete_employee_account(uuid,uuid,uuid) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_delete_admin_account(uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_delete_admin_account(uuid,uuid,uuid) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_list_employee_attendance_settings(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_list_employee_attendance_settings(uuid,uuid) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_employee_attendance_settings(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_employee_attendance_settings(uuid,uuid,jsonb) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_list_attendance_warning_rules(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_list_attendance_warning_rules(uuid,uuid) TO anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.shared_save_attendance_warning_rules(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_save_attendance_warning_rules(uuid,uuid,jsonb) TO anon,authenticated,service_role;

CREATE TABLE public.property_reminder_settings(
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK(kind IN ('todo','calendar')),
  send_when text NOT NULL DEFAULT 'before' CHECK(send_when IN ('before','today','both','off')),
  send_time time NOT NULL DEFAULT '09:00',
  notify_staff boolean NOT NULL DEFAULT true,
  notify_owner boolean NOT NULL DEFAULT true,
  PRIMARY KEY(property_id,kind)
);
ALTER TABLE public.property_reminder_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.property_reminder_settings FROM anon,authenticated;
INSERT INTO public.property_reminder_settings(property_id,kind)
SELECT p.id,k.kind FROM public.properties p CROSS JOIN (VALUES('todo'),('calendar')) k(kind)
ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION omg_private.default_property_reminders() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO public.property_reminder_settings(property_id,kind) VALUES(NEW.id,'todo'),(NEW.id,'calendar') ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER property_reminder_defaults AFTER INSERT ON public.properties FOR EACH ROW EXECUTE FUNCTION omg_private.default_property_reminders();

CREATE OR REPLACE FUNCTION public.get_property_reminder_settings(p_access_token uuid,p_property_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_settings jsonb;
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('kind',k.kind,'send_when',coalesce(s.send_when,'before'),'send_time',coalesce(s.send_time,'09:00'::time),'notify_staff',coalesce(s.notify_staff,true),'notify_owner',coalesce(s.notify_owner,true)) ORDER BY k.kind),'[]'::jsonb) INTO v_settings
 FROM (VALUES('todo'),('calendar')) k(kind) LEFT JOIN public.property_reminder_settings s ON s.property_id=p_property_id AND s.kind=k.kind;
 RETURN jsonb_build_object('ok',true,'settings',v_settings);
END $$;
CREATE OR REPLACE FUNCTION public.save_property_reminder_settings(p_access_token uuid,p_property_id uuid,p_settings jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_item jsonb;
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 IF jsonb_typeof(p_settings)<>'array' OR jsonb_array_length(p_settings)<>2 THEN RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.'); END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_settings) LOOP
   IF v_item->>'kind' NOT IN ('todo','calendar') OR v_item->>'send_when' NOT IN ('before','today','both','off')
      OR (v_item->>'send_time')::time IS NULL OR jsonb_typeof(v_item->'notify_staff')<>'boolean' OR jsonb_typeof(v_item->'notify_owner')<>'boolean' THEN
      RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.');
   END IF;
   INSERT INTO public.property_reminder_settings(property_id,kind,send_when,send_time,notify_staff,notify_owner)
   VALUES(p_property_id,v_item->>'kind',v_item->>'send_when',(v_item->>'send_time')::time,(v_item->>'notify_staff')::boolean,(v_item->>'notify_owner')::boolean)
   ON CONFLICT(property_id,kind) DO UPDATE SET send_when=excluded.send_when,send_time=excluded.send_time,notify_staff=excluded.notify_staff,notify_owner=excluded.notify_owner;
 END LOOP;
 RETURN public.get_property_reminder_settings(p_access_token,p_property_id);
EXCEPTION WHEN invalid_datetime_format THEN RETURN jsonb_build_object('ok',false,'message','발송 시간을 확인해주세요.');
END $$;
REVOKE ALL ON FUNCTION public.get_property_reminder_settings(uuid,uuid),public.save_property_reminder_settings(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_property_reminder_settings(uuid,uuid),public.save_property_reminder_settings(uuid,uuid,jsonb) TO anon,authenticated,service_role;

CREATE TABLE public.reminder_deliveries(
 kind text NOT NULL, item_id uuid NOT NULL, offset_days smallint NOT NULL,
 message_id uuid REFERENCES public.property_messages(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(kind,item_id,offset_days)
);
ALTER TABLE public.reminder_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.reminder_deliveries FROM anon,authenticated;

CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_setting record;v_item record;v_message_id uuid;v_count integer:=0;v_offset integer;v_recipient_count integer;v_secret text;v_url text;
BEGIN
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 FOR v_setting IN
  SELECT s.*,p.business_id,p.management_number,p.timezone,
   (clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'))::date AS local_today
  FROM public.property_reminder_settings s JOIN public.properties p ON p.id=s.property_id
  WHERE s.send_when<>'off' AND (s.notify_staff OR s.notify_owner)
    AND to_char(clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'),'HH24:MI')=to_char(s.send_time,'HH24:MI')
 LOOP
  FOR v_item IN
    SELECT 'todo'::text AS kind,m.id,m.title,m.due_at AS due_at,m.target_employee_ids AS targets, true AS owner_target
      FROM public.missions m WHERE v_setting.kind='todo' AND m.property_id=v_setting.property_id AND m.active AND m.due_at IS NOT NULL
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids),c.owner_target
      FROM public.calendar_events c WHERE v_setting.kind='calendar' AND c.property_id=v_setting.property_id AND c.holiday_request_id IS NULL
  LOOP
   FOR v_offset IN SELECT offset_day FROM (VALUES(0),(1)) offsets(offset_day)
     WHERE (offset_day=0 AND v_setting.send_when IN ('today','both'))
        OR (offset_day=1 AND v_setting.send_when IN ('before','both')) LOOP
     IF (v_item.due_at AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'))::date<>v_setting.local_today+v_offset THEN CONTINUE; END IF;
     INSERT INTO public.reminder_deliveries(kind,item_id,offset_days) VALUES(v_item.kind,v_item.id,v_offset)
     ON CONFLICT DO NOTHING;
     IF NOT FOUND THEN CONTINUE; END IF;
     INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
     VALUES(v_setting.business_id,v_setting.property_id,'system',
       (CASE WHEN v_item.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END)||E'\n'||(CASE WHEN v_offset=1 THEN '내일: ' ELSE '오늘: ' END)||left(v_item.title,120),
       'normal','general','reminder') RETURNING id INTO v_message_id;
     IF v_setting.notify_staff THEN
       INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
       SELECT v_message_id,'employee:'||e.id,'staff',e.id FROM public.employees e
       WHERE e.property_id=v_setting.property_id AND e.active AND e.role<>'owner'
        AND (v_item.kind='todo' AND (jsonb_array_length(coalesce(v_item.targets,'[]'::jsonb))=0 OR to_jsonb(e.id)<@v_item.targets)
          OR v_item.kind='calendar' AND to_jsonb(e.id)<@v_item.targets)
       ON CONFLICT DO NOTHING;
     END IF;
     IF v_setting.notify_owner THEN
       INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
       SELECT v_message_id,'owner:'||o.id,'owner',o.id FROM public.owners o WHERE o.property_id=v_setting.property_id AND o.active
       ON CONFLICT DO NOTHING;
     END IF;
     SELECT count(*) INTO v_recipient_count FROM public.property_message_recipients WHERE message_id=v_message_id;
     IF v_recipient_count=0 THEN
       DELETE FROM public.reminder_deliveries WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND message_id IS NULL;
       DELETE FROM public.property_messages WHERE id=v_message_id;
       CONTINUE;
     END IF;
     UPDATE public.reminder_deliveries SET message_id=v_message_id WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset;
     v_url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder';
     PERFORM net.http_post(url:=v_url,headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message_id));
     v_count:=v_count+1;
   END LOOP;
  END LOOP;
 END LOOP;
 RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION omg_private.enqueue_due_reminders() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.get_reminder_push_dispatch(p_message_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_message record;v_topics jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT m.*,p.management_number INTO v_message FROM public.property_messages m JOIN public.properties p ON p.id=m.property_id
 WHERE m.id=p_message_id AND m.source='reminder';
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT coalesce(jsonb_agg('property_'||v_message.management_number||'_'||
     CASE WHEN r.recipient_type='staff' THEN 'employee_'||r.employee_id ELSE 'owner_'||r.owner_id END),'[]'::jsonb)
 INTO v_topics FROM public.property_message_recipients r WHERE r.message_id=p_message_id;
 RETURN jsonb_build_object('ok',true,'message_id',p_message_id,'message',v_message.message,'recipient_topics',v_topics);
END $$;
REVOKE ALL ON FUNCTION public.get_reminder_push_dispatch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_reminder_push_dispatch(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.list_shared_calendar_board(p_access_token uuid,p_property_ids uuid[],p_from timestamptz,p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_own uuid;v_events jsonb;v_tasks jsonb;
BEGIN
 SELECT s.property_id INTO v_own FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_access_token) AND s.token_expires_at>clock_timestamp() AND o.active;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'message','관리자 로그인 후 이용해주세요.'); END IF;
 IF cardinality(p_property_ids) NOT BETWEEN 1 AND 20 OR p_from IS NULL OR p_to<=p_from OR p_to-p_from>interval '62 days'
    OR EXISTS(SELECT 1 FROM unnest(p_property_ids) id WHERE NOT omg_private.can_manage_shared_property(p_access_token,id,'missions')) THEN
   RETURN jsonb_build_object('ok',false,'message','조회 기간 또는 숙소 권한을 확인해주세요.');
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'property_id',c.property_id,'property_name',p.name,'title',c.title,'details',c.details,'start_at',c.start_at,'end_at',c.end_at,
   'all_day',c.all_day,'owner_target',c.owner_target,'target_employee_ids',c.target_employee_ids,
   'creator_kind',c.creator_kind,'holiday_request_id',c.holiday_request_id,
   'can_edit',c.property_id=v_own AND c.holiday_request_id IS NULL,
   'target_names',coalesce((SELECT jsonb_agg(e.display_name ORDER BY e.display_name) FROM public.employees e WHERE e.id=any(c.target_employee_ids)),'[]'::jsonb)
 ) ORDER BY c.start_at,c.created_at),'[]'::jsonb) INTO v_events
 FROM public.calendar_events c JOIN public.properties p ON p.id=c.property_id
 WHERE c.property_id=any(p_property_ids) AND c.start_at<p_to AND c.end_at>p_from;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,
   'target_employee_ids',m.target_employee_ids) ORDER BY m.due_at,m.created_at),'[]'::jsonb) INTO v_tasks
 FROM public.missions m JOIN public.properties p ON p.id=m.property_id
 WHERE m.property_id=any(p_property_ids) AND m.active AND m.creator_type='owner' AND m.due_at>=p_from AND m.due_at<p_to;
 RETURN jsonb_build_object('ok',true,'events',v_events,'tasks',v_tasks);
END $$;
REVOKE ALL ON FUNCTION public.list_shared_calendar_board(uuid,uuid[],timestamptz,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_shared_calendar_board(uuid,uuid[],timestamptz,timestamptz) TO anon,authenticated,service_role;
SELECT cron.schedule('omg-reminder-dispatch','* * * * *','SELECT omg_private.enqueue_due_reminders()');
