-- Property business types and owner-defined report fields.
begin;

alter table public.properties
  add column if not exists business_type text,
  add column if not exists custom_report_fields jsonb not null default '[]'::jsonb;

-- Commit the table shape before compiling functions that access the new
-- columns through properties%rowtype. On hosted Postgres, compiling those
-- functions in the same transaction can still see the pre-ALTER row type and
-- roll the whole migration back with `column custom_report_fields does not
-- exist`.
commit;
begin;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname='properties_business_type_check' and conrelid='public.properties'::regclass
  ) then
    alter table public.properties add constraint properties_business_type_check
      check (business_type is null or business_type in ('lodging','general','other'));
  end if;
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname='properties_custom_report_fields_array_check' and conrelid='public.properties'::regclass
  ) then
    alter table public.properties add constraint properties_custom_report_fields_array_check
      check (jsonb_typeof(custom_report_fields)='array');
  end if;
end;
$$;

create or replace function omg_private.custom_report_fields_are_valid(p_fields jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(
    jsonb_typeof(p_fields)='array'
    and jsonb_array_length(p_fields)<=20
    and octet_length(p_fields::text)<=5000
    and not exists (
      select 1 from jsonb_array_elements(p_fields) item(value)
      where jsonb_typeof(item.value)<>'object'
        or coalesce(item.value->>'key','') !~ '^custom_[a-z0-9_-]{1,50}$'
        or char_length(btrim(coalesce(item.value->>'label',''))) not between 1 and 40
    )
    and (
      select count(*)=count(distinct item.value->>'key')
      from jsonb_array_elements(p_fields) item(value)
    ),false
  );
$$;

create or replace function omg_private.report_config_is_valid(p_config jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(
    jsonb_typeof(p_config)='object'
    and jsonb_typeof(p_config->'clock_in')='array'
    and jsonb_typeof(p_config->'clock_out')='array'
    and jsonb_typeof(p_config->'reminder_cards')='array'
    and jsonb_array_length(p_config->'clock_in')<=27
    and jsonb_array_length(p_config->'clock_out')<=27
    and jsonb_array_length(p_config->'reminder_cards')<=12
    and octet_length(p_config::text)<=6000000
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_in') item(value)
      where item.value<>all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','cleaned_rooms','inspected_rooms','reminder_cards'])
        and item.value !~ '^custom_[a-z0-9_-]{1,50}$')
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_out') item(value)
      where item.value<>all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','cleaned_rooms','inspected_rooms','reminder_cards'])
        and item.value !~ '^custom_[a-z0-9_-]{1,50}$')
    and not exists(select 1 from jsonb_array_elements(p_config->'reminder_cards') item(value)
      where jsonb_typeof(item.value)<>'object'
        or btrim(coalesce(item.value->>'id',''))='' or char_length(item.value->>'id')>50
        or btrim(coalesce(item.value->>'title',''))='' or char_length(item.value->>'title')>50
        or btrim(coalesce(item.value->>'text',''))='' or char_length(item.value->>'text')>1000
        or btrim(coalesce(item.value->>'image',''))='' or octet_length(item.value->>'image')>900000
        or jsonb_typeof(item.value->'weekdays')<>'array'
        or jsonb_array_length(item.value->'weekdays')>7
        or exists(select 1 from jsonb_array_elements_text(item.value->'weekdays') day(value)
          where day.value !~ '^[0-6]$')
    ),false
  );
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
    'rooms',v_property.rooms,'room_types',v_property.room_types,'business_type',v_property.business_type,
    'custom_report_fields',v_property.custom_report_fields,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'administrators',v_administrators,'can_manage',v_can_manage);
end;
$$;

create or replace function public.save_property_settings(
  p_access_token uuid,
  p_property_name text,
  p_rooms jsonb,
  p_employee_configs jsonb,
  p_room_types jsonb,
  p_business_type text,
  p_custom_report_fields jsonb
)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  return public.get_work_app_config(p_access_token);
end;
$$;

revoke all on function omg_private.custom_report_fields_are_valid(jsonb) from public,anon,authenticated;
revoke all on function public.save_property_settings(uuid,text,jsonb,jsonb,jsonb,text,jsonb) from public;
grant execute on function public.save_property_settings(uuid,text,jsonb,jsonb,jsonb,text,jsonb) to anon,authenticated;

commit;
select '사업장 유형·사용자 보고 항목 준비 완료' as result;
