-- Attendance classification, flexible announcements and expanded warning rules.
begin;

alter table public.employees
  add column if not exists lateness_threshold_minutes integer;

alter table public.employees drop constraint if exists employees_lateness_threshold_minutes_check;
alter table public.employees add constraint employees_lateness_threshold_minutes_check
  check(lateness_threshold_minutes is null or lateness_threshold_minutes between 0 and 720);

alter table public.attendance_warning_rules drop constraint if exists attendance_warning_rules_event_type_check;
alter table public.attendance_warning_rules add constraint attendance_warning_rules_event_type_check
  check(event_type in('clock_in','clock_out','work_duration'));
alter table public.attendance_warning_rules drop constraint if exists attendance_warning_rules_comparison_check;
alter table public.attendance_warning_rules add constraint attendance_warning_rules_comparison_check
  check(comparison in('late','early','both'));
alter table public.attendance_warning_deliveries drop constraint if exists attendance_warning_deliveries_event_type_check;
alter table public.attendance_warning_deliveries add constraint attendance_warning_deliveries_event_type_check
  check(event_type in('clock_in','clock_out','work_duration'));

create or replace function omg_private.attendance_labels(
  p_work_date date,p_clock_in_at timestamptz,p_clock_out_at timestamptz,
  p_scheduled_in time,p_scheduled_out time,p_lateness_minutes integer,p_timezone text
) returns jsonb language plpgsql stable set search_path='' as $$
declare v_labels jsonb:='[]'::jsonb;v_expected_in timestamptz;v_expected_out timestamptz;
  v_scheduled_minutes integer;v_actual_minutes integer;
begin
  if p_scheduled_in is not null then
    v_expected_in:=(p_work_date+p_scheduled_in) at time zone p_timezone;
    if p_clock_in_at>v_expected_in+make_interval(mins=>coalesce(p_lateness_minutes,0)) then
      v_labels:=v_labels||jsonb_build_array('지각');
    end if;
  end if;
  if p_scheduled_out is not null and p_clock_out_at is not null then
    v_expected_out:=(p_work_date+p_scheduled_out+case when p_scheduled_in is not null and p_scheduled_out<=p_scheduled_in
      then interval '1 day' else interval '0' end) at time zone p_timezone;
    if p_clock_out_at>v_expected_out then v_labels:=v_labels||jsonb_build_array('야근'); end if;
  end if;
  if p_scheduled_in is not null and p_scheduled_out is not null and p_clock_in_at is not null and p_clock_out_at is not null then
    v_scheduled_minutes:=floor(extract(epoch from(
      (p_work_date+p_scheduled_out+case when p_scheduled_out<=p_scheduled_in then interval '1 day' else interval '0' end)
      -(p_work_date+p_scheduled_in)))/60)::integer;
    v_actual_minutes:=greatest(0,floor(extract(epoch from(p_clock_out_at-p_clock_in_at))/60)::integer);
    if v_actual_minutes>v_scheduled_minutes then v_labels:=v_labels||jsonb_build_array('오버타임'); end if;
  end if;
  if jsonb_array_length(v_labels)=0 then return jsonb_build_array('정상'); end if;
  return v_labels;
end;
$$;

create or replace function public.list_attendance_classifications(p_access_token uuid,p_session_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_property_id uuid;v_employee_id uuid;v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_owner_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id into v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('session_id',s.id,'attendance_labels',
    omg_private.attendance_labels(s.work_date,s.clock_in_at,s.clock_out_at,e.scheduled_clock_in,e.scheduled_clock_out,
      e.lateness_threshold_minutes,p.timezone))),'[]'::jsonb) into v_items
  from public.work_sessions s join public.employees e on e.id=s.employee_id join public.properties p on p.id=s.property_id
  where s.id=any(coalesce(p_session_ids,'{}'::uuid[])) and(
    (v_employee_id is not null and s.employee_id=v_employee_id)or
    (v_owner_property_id is not null and(s.property_id=v_owner_property_id or exists(
      select 1 from public.property_share_requests r where r.requester_property_id=v_owner_property_id
        and r.target_property_id=s.property_id and r.status='approved' and 'attendance'=any(r.requested_permissions)))));
  return jsonb_build_object('ok',true,'items',v_items);
end;
$$;

create or replace function public.list_employee_attendance_settings(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 설정을 볼 수 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'lateness_threshold_minutes',e.lateness_threshold_minutes)
    order by e.created_at,e.id),'[]'::jsonb) into v_items
  from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
  return jsonb_build_object('ok',true,'settings',v_items);
end;
$$;

create or replace function public.save_employee_attendance_settings(p_access_token uuid,p_employees jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_item jsonb;v_employee_id uuid;v_minutes integer;v_name text;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 설정을 저장할 수 있습니다.'); end if;
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
  return public.list_employee_attendance_settings(p_access_token);
end;
$$;

create or replace function public.save_attendance_warning_rules(p_access_token uuid,p_rules jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_id uuid;v_property_id uuid;v_item jsonb;v_rule_id uuid;v_employee_id uuid;
  v_event text;v_comparison text;v_minutes integer;v_message text;v_active boolean;v_keep uuid[]:='{}'::uuid[];
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_rules)<>'array' or jsonb_array_length(p_rules)>50 then
    return jsonb_build_object('ok',false,'code','invalid_rules','message','근무시간 워닝 조건을 확인해주세요.'); end if;
  for v_item in select value from jsonb_array_elements(p_rules) loop
    begin
      v_rule_id:=nullif(v_item->>'rule_id','')::uuid;v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
      v_minutes:=coalesce((v_item->>'threshold_minutes')::integer,0);
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_rule','message','근무시간 워닝 조건을 확인해주세요.');
    end;
    v_event:=coalesce(v_item->>'event_type','');v_comparison:=coalesce(v_item->>'comparison','');
    v_message:=btrim(coalesce(v_item->>'message',''));v_active:=coalesce((v_item->>'active')::boolean,true);
    if v_employee_id is null or not exists(select 1 from public.employees e where e.id=v_employee_id and e.property_id=v_property_id and e.active and e.role<>'owner')
      or v_event not in('clock_in','clock_out','work_duration') or v_comparison not in('late','early','both')
      or v_minutes not between 0 and 720 or char_length(v_message) not between 1 and 1000 then
      return jsonb_build_object('ok',false,'code','invalid_rule','message','대상·조건·시간·공지 내용을 모두 확인해주세요.'); end if;
    if(v_event='clock_in' and(select scheduled_clock_in from public.employees where id=v_employee_id)is null)
      or(v_event='clock_out' and(select scheduled_clock_out from public.employees where id=v_employee_id)is null)
      or(v_event='work_duration' and exists(select 1 from public.employees where id=v_employee_id
        and(scheduled_clock_in is null or scheduled_clock_out is null))) then
      return jsonb_build_object('ok',false,'code','schedule_required','message','선택한 근무자의 예정 출퇴근 시간을 먼저 입력해주세요.'); end if;
    if v_rule_id is null then
      insert into public.attendance_warning_rules(business_id,property_id,employee_id,event_type,comparison,threshold_minutes,message,active)
      values(v_business_id,v_property_id,v_employee_id,v_event,v_comparison,v_minutes,v_message,v_active) returning id into v_rule_id;
    else
      update public.attendance_warning_rules set employee_id=v_employee_id,event_type=v_event,comparison=v_comparison,
        threshold_minutes=v_minutes,message=v_message,active=v_active,updated_at=clock_timestamp()
      where id=v_rule_id and property_id=v_property_id;
      if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 워닝 조건을 찾지 못했습니다.'); end if;
    end if;
    v_keep:=array_append(v_keep,v_rule_id);
  end loop;
  delete from public.attendance_warning_rules where property_id=v_property_id and not(id=any(v_keep));
  return public.list_attendance_warning_rules(p_access_token);
end;
$$;

create or replace function public.evaluate_attendance_warnings(p_access_token uuid,p_report_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_actual timestamptz;v_expected timestamptz;v_scheduled time;v_diff integer;v_rule public.attendance_warning_rules%rowtype;
  v_message_id uuid;v_message_ids jsonb:='[]'::jsonb;v_text text;v_triggered boolean;v_expected_text text;v_actual_text text;
  v_scheduled_minutes integer;v_actual_minutes integer;
begin
  if p_report_type not in('clock_in','clock_out') then return jsonb_build_object('ok',false,'message','보고 종류를 확인해주세요.'); end if;
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  select * into v_employee from public.employees where id=v_session.employee_id;
  select * into v_property from public.properties where id=v_session.property_id;
  for v_rule in select * from public.attendance_warning_rules where property_id=v_session.property_id
    and employee_id=v_session.employee_id and active and(event_type=p_report_type or(p_report_type='clock_out' and event_type='work_duration'))
    order by created_at loop
    if v_rule.event_type='work_duration' then
      if v_session.clock_in_at is null or v_session.clock_out_at is null or v_employee.scheduled_clock_in is null or v_employee.scheduled_clock_out is null then continue; end if;
      v_scheduled_minutes:=floor(extract(epoch from((v_session.work_date+v_employee.scheduled_clock_out+
        case when v_employee.scheduled_clock_out<=v_employee.scheduled_clock_in then interval '1 day' else interval '0' end)
        -(v_session.work_date+v_employee.scheduled_clock_in)))/60)::integer;
      v_actual_minutes:=greatest(0,floor(extract(epoch from(v_session.clock_out_at-v_session.clock_in_at))/60)::integer);
      v_diff:=v_actual_minutes-v_scheduled_minutes;
      v_expected_text:=(v_scheduled_minutes/60)::text||'시간 '||(v_scheduled_minutes%60)::text||'분';
      v_actual_text:=(v_actual_minutes/60)::text||'시간 '||(v_actual_minutes%60)::text||'분';
    else
      if v_rule.event_type='clock_in' then v_actual:=v_session.clock_in_at;v_scheduled:=v_employee.scheduled_clock_in;
      else v_actual:=v_session.clock_out_at;v_scheduled:=v_employee.scheduled_clock_out;end if;
      if v_actual is null or v_scheduled is null then continue; end if;
      v_expected:=(v_session.work_date+v_scheduled+case when v_rule.event_type='clock_out' and v_employee.scheduled_clock_in is not null
        and v_scheduled<=v_employee.scheduled_clock_in then interval '1 day' else interval '0' end) at time zone v_property.timezone;
      v_diff:=floor(extract(epoch from(v_actual-v_expected))/60)::integer;
      v_expected_text:=to_char(v_expected at time zone v_property.timezone,'HH24:MI');
      v_actual_text:=to_char(v_actual at time zone v_property.timezone,'HH24:MI');
    end if;
    v_triggered:=(v_rule.comparison='late' and v_diff>=v_rule.threshold_minutes)
      or(v_rule.comparison='early' and v_diff<=-v_rule.threshold_minutes)
      or(v_rule.comparison='both' and abs(v_diff)>=v_rule.threshold_minutes);
    if v_triggered and not exists(select 1 from public.attendance_warning_deliveries d
      where d.rule_id=v_rule.id and d.work_session_id=v_session.id and d.event_type=v_rule.event_type) then
      v_text:=replace(replace(replace(replace(v_rule.message,'{이름}',v_employee.display_name),'{예정시간}',v_expected_text),
        '{실제시간}',v_actual_text),'{차이분}',abs(v_diff)::text);
      insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type)
      values(v_property.business_id,v_property.id,'system',v_text,'normal','announcement') returning id into v_message_id;
      insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
      values(v_message_id,'employee:'||v_employee.id,'staff',v_employee.id);
      insert into public.attendance_warning_deliveries(rule_id,work_session_id,event_type,message_id)
      values(v_rule.id,v_session.id,v_rule.event_type,v_message_id);
      v_message_ids:=v_message_ids||jsonb_build_array(v_message_id);
    end if;
  end loop;
  return jsonb_build_object('ok',true,'message_ids',v_message_ids);
end;
$$;

create or replace function public.send_shared_property_message(
  p_access_token uuid,p_recipient_employee_ids uuid[],p_recipient_owner_ids uuid[],p_message text,
  p_priority text default 'normal',p_message_type text default 'general')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property public.properties%rowtype;
  v_sender_type text;v_message_id uuid;v_text text:=btrim(coalesce(p_message,''));
  v_employee_ids uuid[]:=coalesce(p_recipient_employee_ids,'{}'::uuid[]);v_owner_ids uuid[]:=coalesce(p_recipient_owner_ids,'{}'::uuid[]);
  v_employee_count integer:=0;v_owner_count integer:=0;
begin
  if char_length(v_text) not between 1 and 2000 then return jsonb_build_object('ok',false,'code','invalid_message','message','메세지 내용을 입력해주세요.'); end if;
  if p_priority not in('normal','urgent') or p_message_type not in('general','emergency_report','announcement') then
    return jsonb_build_object('ok',false,'code','invalid_message_type','message','메세지 종류를 확인해주세요.'); end if;
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_sender_type:='owner';select * into v_property from public.properties where id=v_owner_session.property_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    if p_message_type='announcement' then return jsonb_build_object('ok',false,'code','owner_required','message','공지는 관리자만 보낼 수 있습니다.'); end if;
    v_sender_type:='staff';select * into v_property from public.properties where id=v_work_session.property_id;
    v_employee_ids:=array_remove(v_employee_ids,v_work_session.employee_id);
  end if;
  if p_message_type='announcement' then p_priority:='normal';v_owner_ids:='{}'::uuid[];end if;
  select count(*)::integer into v_employee_count from public.employees e where e.active and e.role<>'owner' and e.id=any(v_employee_ids) and(
    e.property_id=v_property.id or exists(select 1 from public.property_share_requests r where r.status='approved'
      and 'messages'=any(r.requested_permissions) and((r.requester_property_id=v_property.id and r.target_property_id=e.property_id)
      or(v_sender_type='staff' and r.target_property_id=v_property.id and r.requester_property_id=e.property_id))));
  if v_employee_count<>coalesce(cardinality(v_employee_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 직원이 포함되어 있습니다.'); end if;
  select count(*)::integer into v_owner_count from public.owners o where o.active and o.id=any(v_owner_ids) and(
    (v_sender_type='staff' and(o.property_id=v_property.id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property.id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))))
    or(v_sender_type='owner' and o.property_id=v_property.id and o.id<>v_owner_session.owner_id));
  if v_owner_count<>coalesce(cardinality(v_owner_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 관리자가 포함되어 있습니다.'); end if;
  if v_employee_count+v_owner_count=0 then return jsonb_build_object('ok',false,'code','recipient_required','message','받는 사람을 한 명 이상 선택해주세요.'); end if;
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,message_type)
  values(v_property.business_id,v_property.id,v_sender_type,case when v_sender_type='owner' then v_owner_session.owner_id end,
    case when v_sender_type='staff' then v_work_session.employee_id end,v_text,p_priority,p_message_type) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
  select v_message_id,'employee:'||e.id,'staff',e.id from public.employees e where e.id=any(v_employee_ids);
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.id=any(v_owner_ids);
  return jsonb_build_object('ok',true,'message_id',v_message_id,'priority',p_priority,'message_type',p_message_type,
    'recipient_count',v_employee_count+v_owner_count,'sent_at',clock_timestamp());
end;
$$;

revoke all on function public.list_attendance_classifications(uuid,uuid[]) from public;
revoke all on function public.list_employee_attendance_settings(uuid) from public;
revoke all on function public.save_employee_attendance_settings(uuid,jsonb) from public;
grant execute on function public.list_attendance_classifications(uuid,uuid[]) to anon,authenticated;
grant execute on function public.list_employee_attendance_settings(uuid) to anon,authenticated;
grant execute on function public.save_employee_attendance_settings(uuid,jsonb) to anon,authenticated;

commit;

select 'attendance classification and notice recipients installed' as migration_status;
