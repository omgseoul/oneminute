begin;
CREATE OR REPLACE FUNCTION omg_private.room_types_are_valid(p_room_types jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(
    jsonb_typeof(p_room_types) = 'array'
    and jsonb_array_length(p_room_types) between 1 and 30
    and not exists (
      select 1 from jsonb_array_elements(p_room_types) group_item(value)
      where jsonb_typeof(group_item.value) <> 'object'
        or btrim(coalesce(group_item.value->>'name','')) = ''
        or char_length(btrim(group_item.value->>'name')) > 40
        or jsonb_typeof(group_item.value->'rooms') <> 'array'
        or jsonb_array_length(group_item.value->'rooms') > 100
        or exists (
          select 1 from jsonb_array_elements_text(group_item.value->'rooms') room(value)
          where btrim(room.value) = '' or char_length(btrim(room.value)) > 30
        )
    )
    and (select count(*) from jsonb_array_elements(p_room_types) g(value),
      jsonb_array_elements_text(g.value->'rooms') r(value)) <= 100
    and (select count(*) from jsonb_array_elements(p_room_types) g(value),
      jsonb_array_elements_text(g.value->'rooms') r(value))
      = (select count(distinct btrim(r.value)) from jsonb_array_elements(p_room_types) g(value),
        jsonb_array_elements_text(g.value->'rooms') r(value)),
    false
  );
$function$;
CREATE OR REPLACE FUNCTION public.save_property_settings(p_access_token uuid, p_property_name text, p_rooms jsonb, p_employee_configs jsonb, p_room_types jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_property_id uuid;
  v_name text := btrim(coalesce(p_property_name,''));
  v_rooms jsonb;
  v_room_types jsonb;
  v_pair record;
  v_employee_id uuid;
begin
  select s.property_id into v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 설정을 변경할 수 있습니다.'); end if;
  if char_length(v_name) not between 1 and 80 then
    return jsonb_build_object('ok',false,'code','invalid_name','message','숙소 이름은 1~80자로 입력해주세요.');
  end if;
  if omg_private.room_types_are_valid(p_room_types) is not true then
    return jsonb_build_object('ok',false,'code','invalid_room_types','message','객실 타입과 객실번호를 확인해주세요. 같은 객실번호는 한 번만 입력할 수 있습니다.');
  end if;
  select jsonb_agg(jsonb_build_object('name',btrim(group_item.value->>'name'),'rooms',
    coalesce((select jsonb_agg(btrim(room.value) order by room.position)
      from jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)),'[]'::jsonb))
    order by group_item.position)
  into v_room_types
  from jsonb_array_elements(p_room_types) with ordinality group_item(value,position);
  select coalesce(jsonb_agg(room.value order by room.group_position,room.room_position),'[]'::jsonb)
  into v_rooms
  from (
    select btrim(room.value) value,group_item.position group_position,room.position room_position
    from jsonb_array_elements(v_room_types) with ordinality group_item(value,position),
      jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)
  ) room;
  if jsonb_typeof(p_employee_configs) <> 'object' then
    return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.');
  end if;
  for v_pair in select * from jsonb_each(p_employee_configs) loop
    begin v_employee_id := v_pair.key::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.');
    end;
    if omg_private.report_config_is_valid(v_pair.value) is not true then
      return jsonb_build_object('ok',false,'code','invalid_employee_config','message','직원별 보고 항목을 확인해주세요.');
    end if;
    if not exists(select 1 from public.employees where id=v_employee_id and property_id=v_property_id and active) then
      return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 직원이 포함되어 있습니다.');
    end if;
  end loop;
  for v_pair in select * from jsonb_each(p_employee_configs) loop
    update public.employees set report_config=v_pair.value
    where id=v_pair.key::uuid and property_id=v_property_id and active;
  end loop;
  update public.properties set name=v_name,rooms=v_rooms,room_types=v_room_types where id=v_property_id;
  return public.get_work_app_config(p_access_token);
end;
$function$;
CREATE OR REPLACE FUNCTION public.save_property_settings(p_access_token uuid, p_property_name text, p_rooms jsonb, p_employee_configs jsonb, p_room_types jsonb, p_business_type text, p_custom_report_fields jsonb)
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
      coalesce((select jsonb_agg(btrim(room.value) order by room.position) from jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)),'[]'::jsonb)) order by group_item.position)
    into v_room_types from jsonb_array_elements(p_room_types) with ordinality group_item(value,position);
    select coalesce(jsonb_agg(room.value order by room.group_position,room.room_position),'[]'::jsonb) into v_rooms from (
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
  return public.get_work_app_config(p_access_token);
end;
$function$;
CREATE OR REPLACE FUNCTION public.shared_save_property_settings(p_access_token uuid, p_property_id uuid, p_property_name text, p_rooms jsonb, p_employee_configs jsonb, p_room_types jsonb, p_business_type text, p_custom_report_fields jsonb)
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
      coalesce((select jsonb_agg(btrim(room.value) order by room.position) from jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)),'[]'::jsonb)) order by group_item.position)
    into v_room_types from jsonb_array_elements(p_room_types) with ordinality group_item(value,position);
    select coalesce(jsonb_agg(room.value order by room.group_position,room.room_position),'[]'::jsonb) into v_rooms from (
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
$function$;
commit;

