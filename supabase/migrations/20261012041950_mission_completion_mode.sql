begin;
alter table public.missions add column if not exists completion_mode text not null default 'all' check (completion_mode in ('all','any'));
create or replace FUNCTION public.save_mission(p_access_token uuid, p_mission jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_business_id uuid;v_property_id uuid;v_employee_id uuid;v_id uuid;v_targets jsonb;v_due timestamptz;
  v_mode text;v_is_owner boolean:=false;v_priority text;v_description_photo text:=coalesce(p_mission->>'description_photo','');
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
  v_mode:=coalesce(p_mission->>'completion_mode','all');
  if v_mode not in ('all','any') or (v_mode='any' and (not v_is_owner or jsonb_array_length(v_targets)<>0)) then
    return jsonb_build_object('ok',false,'code','invalid_completion_mode','message','완료 방식을 확인해주세요.');
  end if;
  begin v_due:=nullif(p_mission->>'due_at','')::timestamptz;
  exception when others then return jsonb_build_object('ok',false,'code','invalid_due_at','message','마감일시를 확인해주세요.'); end;
  begin v_id:=nullif(p_mission->>'id','')::uuid;
  exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션을 확인해주세요.'); end;
  if v_id is null then
    insert into public.missions(business_id,property_id,title,description,description_photo,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at,creator_type,creator_employee_id,completion_mode)
    values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),v_description_photo,p_mission->>'timing',v_priority,
      v_targets,coalesce((p_mission->>'photo_required')::boolean,false),30,v_due,case when v_is_owner then 'owner' else 'staff' end,v_employee_id,v_mode)
    returning id into v_id;
  else
    update public.missions set title=btrim(p_mission->>'title'),description=coalesce(p_mission->>'description',''),description_photo=v_description_photo,
      completion_mode=v_mode,timing=p_mission->>'timing',priority=v_priority,target_employee_ids=v_targets,
      photo_required=coalesce((p_mission->>'photo_required')::boolean,false),due_at=v_due,updated_at=clock_timestamp()
    where id=v_id and property_id=v_property_id and active and v_is_owner;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  end if;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end;
$function$
;
CREATE OR REPLACE FUNCTION public.complete_mission(p_access_token uuid, p_mission_id uuid, p_note text DEFAULT ''::text, p_photo_data_url text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_employee_id uuid; v_property_id uuid; v_mission public.missions%rowtype;
begin
  select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in ('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 완료할 수 있습니다.'); end if;
  select * into v_mission from public.missions where id=p_mission_id and property_id=v_property_id and active and (jsonb_array_length(target_employee_ids)=0 or target_employee_ids ? v_employee_id::text) for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  if v_mission.completion_mode='any' and exists(select 1 from public.mission_completions where mission_id=p_mission_id) then
    return jsonb_build_object('ok',false,'code','already_completed','message','이미 다른 근무자가 완료한 할일입니다.');
  end if;
  if v_mission.photo_required and btrim(coalesce(p_photo_data_url,''))='' then return jsonb_build_object('ok',false,'code','photo_required','message','완료 사진을 올려주세요.'); end if;
  if char_length(coalesce(p_note,''))>1000 or octet_length(coalesce(p_photo_data_url,''))>2000000 then return jsonb_build_object('ok',false,'code','too_large','message','메모 또는 사진 용량을 줄여주세요.'); end if;
  insert into public.mission_completions(mission_id,employee_id,note,photo_data_url) values(p_mission_id,v_employee_id,coalesce(p_note,''),coalesce(p_photo_data_url,'')) on conflict(mission_id,employee_id) do update set note=excluded.note,photo_data_url=excluded.photo_data_url,completed_at=clock_timestamp();
  return jsonb_build_object('ok',true);
end; $function$
;
CREATE OR REPLACE FUNCTION public.list_missions(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'completion_mode',m.completion_mode,'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then '' else coalesce(c.photo_data_url,'') end,
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',case when v_is_owner or m.completion_mode='any' then coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m left join public.employees creator on creator.id=m.creator_employee_id
  left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',v_is_owner);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.list_shared_missions(p_access_token uuid, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_ids uuid[];v_items jsonb:='[]'::jsonb;v_employees jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유 미션을 볼 수 있습니다.'); end if;
  v_ids:=coalesce(p_property_ids,array[v_property_id]);
  if not(v_property_id=any(v_ids)) or exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'missions'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','미션 공유 권한이 없는 지점이 포함되어 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'property_id',p.id,'property_name',p.name)
    order by p.name,e.created_at,e.id),'[]'::jsonb) into v_employees from public.employees e join public.properties p on p.id=e.property_id
    where e.property_id=any(v_ids) and e.active and e.role<>'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'property_id',p.id,'property_name',p.name,'is_own_property',p.id=v_property_id,
    'title',m.title,'description',m.description,'description_photo',m.description_photo,'timing',m.timing,'priority',m.priority,
    'creator_type',m.creator_type,'creator_name',case when m.creator_type='owner' then '관리자' else coalesce(creator.display_name,'근무자') end,
    'completion_mode',m.completion_mode,'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,'completed_at',null,'completion_note',null,'completion_photo','',
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,
      'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc
      join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb),
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp()) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb) into v_items
  from public.missions m join public.properties p on p.id=m.property_id left join public.employees creator on creator.id=m.creator_employee_id
  where m.property_id=any(v_ids) and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',true);
end;
$function$
;
commit;

