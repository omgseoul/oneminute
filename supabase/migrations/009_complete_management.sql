-- Complete property, employee and mission management for the web app.
begin;

alter table public.properties
  add column if not exists room_types jsonb not null default '[]'::jsonb;

update public.properties p
set room_types = case
  when p.rooms = '["401","408","501","508","402","407","502","504","507","403","404","405","503","505","406","506"]'::jsonb
    then '[{"name":"미니싱글","rooms":["401","408","501","508"]},{"name":"싱글","rooms":["402","407","502","504","507"]},{"name":"더블","rooms":["403","404","405","503","505"]},{"name":"패밀리","rooms":["406","506"]}]'::jsonb
  else jsonb_build_array(jsonb_build_object('name','객실','rooms',p.rooms))
end
where p.room_types = '[]'::jsonb and jsonb_array_length(p.rooms) > 0;

create or replace function omg_private.room_types_are_valid(p_room_types jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_room_types) = 'array'
    and jsonb_array_length(p_room_types) between 1 and 30
    and not exists (
      select 1 from jsonb_array_elements(p_room_types) group_item(value)
      where jsonb_typeof(group_item.value) <> 'object'
        or btrim(coalesce(group_item.value->>'name','')) = ''
        or char_length(btrim(group_item.value->>'name')) > 40
        or jsonb_typeof(group_item.value->'rooms') <> 'array'
        or jsonb_array_length(group_item.value->'rooms') < 1
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
$$;

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_session public.work_sessions%rowtype;
  v_employee public.employees%rowtype;
  v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;
  v_can_manage boolean := false;
  v_employees jsonb := '[]'::jsonb;
begin
  select s.* into v_owner_session
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and o.active;
  if found then
    select * into v_property from public.properties where id = v_owner_session.property_id;
    v_can_manage := true;
  else
    select s.* into v_session
    from public.work_sessions s
    join public.employees e on e.id = s.employee_id
    where s.login_token_hash = omg_private.token_hash(p_access_token)
      and s.token_expires_at > clock_timestamp() and e.active
      and s.status in ('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session',
        'message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
    select * into v_employee from public.employees where id = v_session.employee_id;
    select * into v_property from public.properties where id = v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object(
      'employee_id',e.id,'display_name',e.display_name,'role',e.role,
      'pin_ready',e.pin_hash is not null,'report_config',e.report_config
    ) order by e.created_at,e.id),'[]'::jsonb)
    into v_employees from public.employees e
    where e.property_id = v_property.id and e.active and e.role <> 'owner';
  end if;
  return jsonb_build_object(
    'ok',true,
    'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
      'rooms',v_property.rooms,'room_types',v_property.room_types),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'can_manage',v_can_manage
  );
end;
$$;

create or replace function public.save_property_settings(
  p_access_token uuid,
  p_property_name text,
  p_rooms jsonb,
  p_employee_configs jsonb,
  p_room_types jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
    (select jsonb_agg(btrim(room.value) order by room.position)
      from jsonb_array_elements_text(group_item.value->'rooms') with ordinality room(value,position)))
    order by group_item.position)
  into v_room_types
  from jsonb_array_elements(p_room_types) with ordinality group_item(value,position);
  select jsonb_agg(room.value order by room.group_position,room.room_position)
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
$$;

create or replace function public.save_employee_accounts(p_access_token uuid,p_employees jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_business_id uuid;
  v_property_id uuid;
  v_item jsonb;
  v_employee_id uuid;
  v_name text;
  v_pin text;
  v_pin_hash text;
  v_crypto_schema text;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>50 then
    return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.');
  end if;
  select n.nspname into strict v_crypto_schema
  from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid=x.extnamespace
  where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));
    v_pin:=btrim(coalesce(v_item->>'pin',''));
    if char_length(v_name) not between 1 and 50 or (v_pin<>'' and v_pin!~'^[0-9]{6,8}$') then
      return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 이름과 PIN(숫자 6~8자리)을 확인해주세요.');
    end if;
    begin v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 계정을 확인해주세요.');
    end;
    if v_pin<>'' then
      execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema)
      into v_pin_hash using v_pin;
    else v_pin_hash:=null;
    end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,pin_hash,role,active)
      values(v_business_id,v_property_id,v_name,v_pin_hash,'staff',true);
    else
      update public.employees set display_name=v_name,
        pin_hash=coalesce(v_pin_hash,pin_hash),login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.get_work_app_config(p_access_token);
end;
$$;

create or replace function public.save_mission(p_access_token uuid,p_mission jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_business_id uuid;v_property_id uuid;v_id uuid;v_targets jsonb;v_due timestamptz;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 미션을 등록할 수 있습니다.'); end if;
  if jsonb_typeof(p_mission)<>'object' or char_length(btrim(coalesce(p_mission->>'title',''))) not between 1 and 100
    or char_length(coalesce(p_mission->>'description',''))>2000
    or coalesce(p_mission->>'timing','') not in('today','this_week','anytime')
    or coalesce(p_mission->>'priority','') not in('normal','important','urgent') then
    return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
  end if;
  v_targets:=coalesce(p_mission->'target_employee_ids','[]'::jsonb);
  if jsonb_typeof(v_targets)<>'array' or jsonb_array_length(v_targets)>50
    or exists(select 1 from jsonb_array_elements_text(v_targets)x(value)
      where not exists(select 1 from public.employees e where e.id::text=x.value and e.property_id=v_property_id and e.active)) then
    return jsonb_build_object('ok',false,'code','invalid_target','message','담당 근무자를 확인해주세요.');
  end if;
  begin v_due:=nullif(p_mission->>'due_at','')::timestamptz;
  exception when others then return jsonb_build_object('ok',false,'code','invalid_due_at','message','마감일시를 확인해주세요.'); end;
  begin v_id:=nullif(p_mission->>'id','')::uuid;
  exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션을 확인해주세요.'); end;
  if v_id is null then
    insert into public.missions(business_id,property_id,title,description,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at)
    values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),p_mission->>'timing',p_mission->>'priority',v_targets,coalesce((p_mission->>'photo_required')::boolean,false),greatest(1,least(1440,coalesce((p_mission->>'estimated_minutes')::integer,30))),v_due)
    returning id into v_id;
  else
    update public.missions set title=btrim(p_mission->>'title'),description=coalesce(p_mission->>'description',''),
      timing=p_mission->>'timing',priority=p_mission->>'priority',target_employee_ids=v_targets,
      photo_required=coalesce((p_mission->>'photo_required')::boolean,false),
      estimated_minutes=greatest(1,least(1440,coalesce((p_mission->>'estimated_minutes')::integer,30))),
      due_at=v_due,updated_at=clock_timestamp()
    where id=v_id and property_id=v_property_id and active;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  end if;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end;
$$;

revoke all on function omg_private.room_types_are_valid(jsonb) from public,anon,authenticated;
revoke all on function public.save_property_settings(uuid,text,jsonb,jsonb,jsonb) from public;
revoke all on function public.save_employee_accounts(uuid,jsonb) from public;
grant execute on function public.save_property_settings(uuid,text,jsonb,jsonb,jsonb) to anon,authenticated;
grant execute on function public.save_employee_accounts(uuid,jsonb) to anon,authenticated;

commit;
select '통합 관리자 설정 준비 완료' as result;
