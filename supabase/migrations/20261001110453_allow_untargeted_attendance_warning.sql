-- An empty target set keeps a condition configured without sending warnings.
create or replace function public.save_attendance_warning_rules(p_access_token uuid,p_rules jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_id uuid;v_property_id uuid;v_item jsonb;v_rule_id uuid;v_ids uuid[];v_all boolean;
  v_event text;v_comparison text;v_minutes integer;v_message text;v_active boolean;v_keep uuid[]:='{}';
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
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
  return public.list_attendance_warning_rules(p_access_token);
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok',false,'code','invalid_rule','message',case when SQLSTATE='P0001' then SQLERRM else '근무시간 워닝 입력값을 확인해주세요.' end);
end;
$$;
