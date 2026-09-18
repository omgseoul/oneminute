-- Compact owner settings, weekday reminder cards, staff deletion and report editing.
begin;

alter table public.employees alter column report_config set default
  '{"clock_in":["clean_rooms","inspect_rooms","no_show","bedding_stain","reminder_cards"],"clock_out":["cleaned_rooms","inspected_rooms"],"reminder_cards":[{"id":"watch","title":"워치 착용","image":"directive-watch.png","text":"출근 즉시 워치 착용.\n절대 빼지 마세요. 방수임.\n게하폰과 5미터 이내에 있어야 작동합니다.","weekdays":[0,1,2,3,4,5,6]},{"id":"guest-guide","title":"게스트 직접 안내","image":"directive-guest-guide.jpg","text":"짐을 들어주고 문 앞까지 갈 것.\n도어락과 카드키 설명.\n앉아서 말로만 안내하는 건 퇴사 사유임.","weekdays":[0,1,2,3,4,5,6]},{"id":"carry-devices","title":"게하폰·워치 항상 소지","image":"shiba-worker-logo-v2.png","text":"워치와 게하폰을 책상 위에 두고 청소하지 마세요.\n알람을 놓치지 않도록 근무 중 항상 몸에 소지합니다.","weekdays":[0,1,2,3,4,5,6]},{"id":"final-check","title":"객실 최종 확인","image":"shiba-cleaner-logo.png","text":"객실을 나오기 전에 비품, 도어락, 조명, 냉난방 상태를 마지막으로 확인합니다.","weekdays":[0,1,2,3,4,5,6]}]}'::jsonb;

update public.employees e
set report_config=jsonb_set(e.report_config,'{reminder_cards}',
  coalesce((select jsonb_agg(case when card.value ? 'weekdays' then card.value
    else card.value || '{"weekdays":[0,1,2,3,4,5,6]}'::jsonb end order by card.position)
    from jsonb_array_elements(coalesce(e.report_config->'reminder_cards','[]'::jsonb)) with ordinality card(value,position)),'[]'::jsonb),true);

update public.employees e set report_config=jsonb_set(e.report_config,'{reminder_cards}',
  (e.report_config->'reminder_cards') ||
  '[{"id":"carry-devices","title":"게하폰·워치 항상 소지","image":"shiba-worker-logo-v2.png","text":"워치와 게하폰을 책상 위에 두고 청소하지 마세요.\n알람을 놓치지 않도록 근무 중 항상 몸에 소지합니다.","weekdays":[0,1,2,3,4,5,6]}]'::jsonb,true)
where not exists(select 1 from jsonb_array_elements(e.report_config->'reminder_cards') card(value) where card.value->>'id'='carry-devices');

update public.employees e set report_config=jsonb_set(e.report_config,'{reminder_cards}',
  (e.report_config->'reminder_cards') ||
  '[{"id":"final-check","title":"객실 최종 확인","image":"shiba-cleaner-logo.png","text":"객실을 나오기 전에 비품, 도어락, 조명, 냉난방 상태를 마지막으로 확인합니다.","weekdays":[0,1,2,3,4,5,6]}]'::jsonb,true)
where not exists(select 1 from jsonb_array_elements(e.report_config->'reminder_cards') card(value) where card.value->>'id'='final-check');

create or replace function omg_private.report_config_is_valid(p_config jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_config)='object'
    and jsonb_typeof(p_config->'clock_in')='array'
    and jsonb_typeof(p_config->'clock_out')='array'
    and jsonb_typeof(p_config->'reminder_cards')='array'
    and jsonb_array_length(p_config->'clock_in')<=5
    and jsonb_array_length(p_config->'clock_out')<=3
    and jsonb_array_length(p_config->'reminder_cards')<=12
    and octet_length(p_config::text)<=6000000
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_in') item(value)
      where item.value<>all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','reminder_cards']))
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_out') item(value)
      where item.value<>all(array['cleaned_rooms','inspected_rooms','reminder_cards']))
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

create or replace function public.delete_employee_account(p_access_token uuid,p_employee_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_property_id uuid;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 삭제할 수 있습니다.'); end if;
  update public.employees set active=false,login_locked_until=null
  where id=p_employee_id and property_id=v_property_id and active and role<>'owner';
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','삭제할 근무자를 찾을 수 없습니다.'); end if;
  update public.work_sessions set token_expires_at=clock_timestamp()
  where employee_id=p_employee_id and token_expires_at>clock_timestamp();
  return public.get_work_app_config(p_access_token);
end;
$$;

create or replace function public.update_work_report(p_access_token uuid,p_report_type text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_session public.work_sessions%rowtype;v_report public.work_reports%rowtype;v_employee_name text;v_now timestamptz;v_payload jsonb;
begin
  if p_report_type is null or p_report_type not in('clock_in','clock_out') or p_payload is null
    or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>20971520 then
    return jsonb_build_object('ok',false,'code','invalid_report','message','보고서 형식을 확인해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed') for update of s;
  if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  select * into v_report from public.work_reports where work_session_id=v_session.id and report_type=p_report_type for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 기존 보고를 찾을 수 없습니다.'); end if;
  v_now:=clock_timestamp();
  select display_name into v_employee_name from public.employees where id=v_session.employee_id;
  v_payload:=p_payload||jsonb_build_object('worker',v_employee_name,'shift','근무',
    'report_type',case when p_report_type='clock_in' then '출근보고' else '퇴근보고' end,
    'report_id',v_report.id,'work_session_id',v_session.id,'work_date',v_session.work_date,
    'attendance_clock_in_at',v_session.clock_in_at,'submitted_at',v_now,'edited_at',v_now);
  update public.work_reports set payload=v_payload,submitted_at=v_now,make_accepted_at=null where id=v_report.id returning * into v_report;
  return jsonb_build_object('ok',true,'report_id',v_report.id,'already_saved',true,'edited',true,
    'make_accepted',false,'payload',v_report.payload);
end;
$$;

create or replace function public.list_missions(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_property_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'title',m.title,'description',m.description,'timing',m.timing,'priority',m.priority,
    'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'estimated_minutes',m.estimated_minutes,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then '' else coalesce(c.photo_data_url,'') end,
    'completions',case when v_is_owner then coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active and(v_is_owner or jsonb_array_length(m.target_employee_ids)=0 or m.target_employee_ids ? v_employee_id::text);
  return jsonb_build_object('ok',true,'missions',v_items,'can_manage',v_is_owner);
end;
$$;

revoke all on function public.delete_employee_account(uuid,uuid),public.update_work_report(uuid,text,jsonb) from public;
grant execute on function public.delete_employee_account(uuid,uuid),public.update_work_report(uuid,text,jsonb) to anon,authenticated;

commit;
select '설정 압축·요일 카드·보고 수정 준비 완료' as result;
