-- Mission reference photos and property announcements.
begin;

alter table public.properties add column if not exists notice text not null default '';
alter table public.missions add column if not exists description_photo text not null default '';

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;v_can_manage boolean:=false;v_employees jsonb:='[]'::jsonb;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then select * into v_property from public.properties where id=v_owner_session.property_id;v_can_manage:=true;
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
  end if;
  return jsonb_build_object('ok',true,'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
    'rooms',v_property.rooms,'room_types',v_property.room_types,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'can_manage',v_can_manage);
end;
$$;

create or replace function public.save_property_notice(p_access_token uuid,p_notice text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_notice text:=btrim(coalesce(p_notice,''));
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공지사항을 변경할 수 있습니다.'); end if;
  if char_length(v_notice)>2000 then return jsonb_build_object('ok',false,'code','invalid_notice','message','공지사항은 2,000자 이내로 입력해주세요.'); end if;
  update public.properties set notice=v_notice where id=v_property_id;
  return public.get_work_app_config(p_access_token);
end;
$$;

create or replace function public.save_mission(p_access_token uuid,p_mission jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_id uuid;v_property_id uuid;v_employee_id uuid;v_id uuid;v_targets jsonb;v_due timestamptz;
  v_is_owner boolean:=false;v_priority text;v_description_photo text:=coalesce(p_mission->>'description_photo','');
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.business_id,s.property_id,s.employee_id into v_business_id,v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  v_priority:=case when coalesce(p_mission->>'priority','normal') in('important','urgent') then 'important' else 'normal' end;
  if jsonb_typeof(p_mission)<>'object' or char_length(btrim(coalesce(p_mission->>'title',''))) not between 1 and 100
    or char_length(coalesce(p_mission->>'description',''))>2000 or octet_length(v_description_photo)>1500000
    or (v_description_photo<>'' and v_description_photo not like 'data:image/%')
    or coalesce(p_mission->>'timing','') not in('today','this_week','anytime') then
    return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용과 사진을 확인해주세요.');
  end if;
  if v_is_owner then v_targets:=coalesce(p_mission->'target_employee_ids','[]'::jsonb);
  else
    if nullif(p_mission->>'id','') is not null then return jsonb_build_object('ok',false,'code','owner_required','message','직원은 새 미션만 등록할 수 있습니다.'); end if;
    v_targets:=jsonb_build_array(v_employee_id);
  end if;
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
    insert into public.missions(business_id,property_id,title,description,description_photo,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at,creator_type,creator_employee_id)
    values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),v_description_photo,p_mission->>'timing',v_priority,
      v_targets,coalesce((p_mission->>'photo_required')::boolean,false),30,v_due,case when v_is_owner then 'owner' else 'staff' end,v_employee_id)
    returning id into v_id;
  else
    update public.missions set title=btrim(p_mission->>'title'),description=coalesce(p_mission->>'description',''),description_photo=v_description_photo,
      timing=p_mission->>'timing',priority=v_priority,target_employee_ids=v_targets,
      photo_required=coalesce((p_mission->>'photo_required')::boolean,false),due_at=v_due,updated_at=clock_timestamp()
    where id=v_id and property_id=v_property_id and active and v_is_owner;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  end if;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end;
$$;

create or replace function public.list_missions(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb;v_employees jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name) order by e.created_at,e.id),'[]'::jsonb)
  into v_employees from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'title',m.title,'description',m.description,'description_photo',m.description_photo,'timing',m.timing,'priority',m.priority,
    'creator_type',m.creator_type,'creator_name',case when m.creator_type='owner' then '관리자' else coalesce(creator.display_name,'근무자') end,
    'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then '' else coalesce(c.photo_data_url,'') end,
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',case when v_is_owner then coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m left join public.employees creator on creator.id=m.creator_employee_id
  left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',v_is_owner);
end;
$$;

revoke all on function public.save_property_notice(uuid,text),public.save_mission(uuid,jsonb) from public;
grant execute on function public.save_property_notice(uuid,text),public.save_mission(uuid,jsonb) to anon,authenticated;

commit;
select '미션 참고사진·숙소 공지사항 준비 완료' as result;
