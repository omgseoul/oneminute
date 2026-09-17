-- Reminder cards and web missions.
begin;

alter table public.employees alter column report_config set default
  '{"clock_in":["clean_rooms","inspect_rooms","no_show","bedding_stain","reminder_cards"],"clock_out":["cleaned_rooms","inspected_rooms"],"reminder_cards":[{"id":"watch","title":"워치 착용","image":"directive-watch.png","text":"출근 즉시 워치 착용.\n절대 빼지 마세요. 방수임.\n게하폰과 5미터 이내에 있어야 작동합니다."},{"id":"guest-guide","title":"게스트 직접 안내","image":"directive-guest-guide.jpg","text":"짐을 들어주고 문 앞까지 갈 것.\n도어락과 카드키 설명.\n앉아서 말로만 안내하는 건 퇴사 사유임."}]}'::jsonb;

update public.employees
set report_config = jsonb_set(
  jsonb_set(report_config, '{clock_in}',
    case when report_config->'clock_in' ? 'reminder_cards' then report_config->'clock_in'
    else (report_config->'clock_in') || '"reminder_cards"'::jsonb end),
  '{reminder_cards}',
  '[{"id":"watch","title":"워치 착용","image":"directive-watch.png","text":"출근 즉시 워치 착용.\n절대 빼지 마세요. 방수임.\n게하폰과 5미터 이내에 있어야 작동합니다."},{"id":"guest-guide","title":"게스트 직접 안내","image":"directive-guest-guide.jpg","text":"짐을 들어주고 문 앞까지 갈 것.\n도어락과 카드키 설명.\n앉아서 말로만 안내하는 건 퇴사 사유임."}]'::jsonb,
  true)
where report_config->'reminder_cards' is null;

create or replace function omg_private.report_config_is_valid(p_config jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_config) = 'object'
    and jsonb_typeof(p_config -> 'clock_in') = 'array'
    and jsonb_typeof(p_config -> 'clock_out') = 'array'
    and jsonb_typeof(p_config -> 'reminder_cards') = 'array'
    and jsonb_array_length(p_config -> 'clock_in') <= 5
    and jsonb_array_length(p_config -> 'clock_out') <= 3
    and jsonb_array_length(p_config -> 'reminder_cards') <= 6
    and octet_length(p_config::text) <= 6000000
    and not exists (
      select 1 from jsonb_array_elements_text(p_config -> 'clock_in') item(value)
      where item.value <> all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','reminder_cards'])
    )
    and not exists (
      select 1 from jsonb_array_elements_text(p_config -> 'clock_out') item(value)
      where item.value <> all(array['cleaned_rooms','inspected_rooms','reminder_cards'])
    )
    and not exists (
      select 1 from jsonb_array_elements(p_config -> 'reminder_cards') item(value)
      where jsonb_typeof(item.value) <> 'object'
        or btrim(coalesce(item.value->>'id','')) = '' or char_length(item.value->>'id') > 50
        or btrim(coalesce(item.value->>'title','')) = '' or char_length(item.value->>'title') > 50
        or btrim(coalesce(item.value->>'text','')) = '' or char_length(item.value->>'text') > 1000
        or btrim(coalesce(item.value->>'image','')) = '' or octet_length(item.value->>'image') > 900000
    ), false
  );
$$;

create table if not exists public.missions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  title text not null,
  description text not null default '',
  timing text not null default 'today' check (timing in ('today','this_week','anytime')),
  priority text not null default 'normal' check (priority in ('normal','important','urgent')),
  target_employee_ids jsonb not null default '[]'::jsonb,
  photo_required boolean not null default false,
  estimated_minutes integer not null default 30 check (estimated_minutes between 1 and 1440),
  due_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id, property_id) references public.properties(business_id, id),
  check (char_length(title) between 1 and 100),
  check (char_length(description) <= 2000),
  check (jsonb_typeof(target_employee_ids) = 'array')
);

create table if not exists public.mission_completions (
  id uuid primary key default gen_random_uuid(),
  mission_id uuid not null references public.missions(id),
  employee_id uuid not null references public.employees(id),
  note text not null default '',
  photo_data_url text not null default '',
  completed_at timestamptz not null default now(),
  unique (mission_id, employee_id),
  check (char_length(note) <= 1000),
  check (octet_length(photo_data_url) <= 2000000)
);

alter table public.missions enable row level security;
alter table public.mission_completions enable row level security;
revoke all on table public.missions, public.mission_completions from public, anon, authenticated;

create or replace function public.list_missions(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_property_id uuid; v_employee_id uuid; v_is_owner boolean := false; v_items jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner := true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in ('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'title',m.title,'description',m.description,'timing',m.timing,'priority',m.priority,
    'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'estimated_minutes',m.estimated_minutes,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then c.photo_data_url else '' end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then (select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by (m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m
  left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active
    and (v_is_owner or jsonb_array_length(m.target_employee_ids)=0 or m.target_employee_ids ? v_employee_id::text);
  return jsonb_build_object('ok',true,'missions',v_items,'can_manage',v_is_owner);
end; $$;

create or replace function public.save_mission(p_access_token uuid,p_mission jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_business_id uuid; v_property_id uuid; v_id uuid; v_targets jsonb; v_due timestamptz;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','사장 계정만 미션을 등록할 수 있습니다.'); end if;
  if jsonb_typeof(p_mission)<>'object' or char_length(btrim(coalesce(p_mission->>'title',''))) not between 1 and 100
    or char_length(coalesce(p_mission->>'description',''))>2000
    or coalesce(p_mission->>'timing','') not in ('today','this_week','anytime')
    or coalesce(p_mission->>'priority','') not in ('normal','important','urgent') then
    return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
  end if;
  v_targets:=coalesce(p_mission->'target_employee_ids','[]'::jsonb);
  if jsonb_typeof(v_targets)<>'array' or jsonb_array_length(v_targets)>50 or exists(select 1 from jsonb_array_elements_text(v_targets) x(value) where not exists(select 1 from public.employees e where e.id::text=x.value and e.property_id=v_property_id and e.active)) then
    return jsonb_build_object('ok',false,'code','invalid_target','message','담당 근무자를 확인해주세요.');
  end if;
  begin v_due:=nullif(p_mission->>'due_at','')::timestamptz; exception when others then return jsonb_build_object('ok',false,'code','invalid_due_at','message','마감일시를 확인해주세요.'); end;
  insert into public.missions(business_id,property_id,title,description,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at)
  values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),p_mission->>'timing',p_mission->>'priority',v_targets,coalesce((p_mission->>'photo_required')::boolean,false),greatest(1,least(1440,coalesce((p_mission->>'estimated_minutes')::integer,30))),v_due) returning id into v_id;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end; $$;

create or replace function public.archive_mission(p_access_token uuid,p_mission_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_property_id uuid;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','사장 계정만 미션을 종료할 수 있습니다.'); end if;
  update public.missions set active=false,updated_at=clock_timestamp() where id=p_mission_id and property_id=v_property_id;
  return jsonb_build_object('ok',found);
end; $$;

create or replace function public.complete_mission(p_access_token uuid,p_mission_id uuid,p_note text default '',p_photo_data_url text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_employee_id uuid; v_property_id uuid; v_mission public.missions%rowtype;
begin
  select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in ('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 완료할 수 있습니다.'); end if;
  select * into v_mission from public.missions where id=p_mission_id and property_id=v_property_id and active and (jsonb_array_length(target_employee_ids)=0 or target_employee_ids ? v_employee_id::text);
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  if v_mission.photo_required and btrim(coalesce(p_photo_data_url,''))='' then return jsonb_build_object('ok',false,'code','photo_required','message','완료 사진을 올려주세요.'); end if;
  if char_length(coalesce(p_note,''))>1000 or octet_length(coalesce(p_photo_data_url,''))>2000000 then return jsonb_build_object('ok',false,'code','too_large','message','메모 또는 사진 용량을 줄여주세요.'); end if;
  insert into public.mission_completions(mission_id,employee_id,note,photo_data_url) values(p_mission_id,v_employee_id,coalesce(p_note,''),coalesce(p_photo_data_url,'')) on conflict(mission_id,employee_id) do update set note=excluded.note,photo_data_url=excluded.photo_data_url,completed_at=clock_timestamp();
  return jsonb_build_object('ok',true);
end; $$;

revoke all on function public.list_missions(uuid),public.save_mission(uuid,jsonb),public.archive_mission(uuid,uuid),public.complete_mission(uuid,uuid,text,text) from public;
grant execute on function public.list_missions(uuid),public.save_mission(uuid,jsonb),public.archive_mission(uuid,uuid),public.complete_mission(uuid,uuid,text,text) to anon,authenticated;
commit;
select '미션과 리마인더 카드 준비 완료' as result;
