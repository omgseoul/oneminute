-- Multiple warning recipients, one arrival evaluation per local login day, attendance labels.
begin;
alter table public.attendance_warning_rules add column if not exists target_employee_ids uuid[] not null default '{}',
  add column if not exists target_all boolean not null default false;
update public.attendance_warning_rules set target_employee_ids=array[employee_id]
  where employee_id is not null and cardinality(target_employee_ids)=0 and not target_all;
create table if not exists public.attendance_login_checks(
 employee_id uuid not null references public.employees(id) on delete cascade,
 property_id uuid not null references public.properties(id) on delete cascade,
 login_date date not null,first_login_at timestamptz not null,
 primary key(employee_id,property_id,login_date)
);
alter table public.attendance_login_checks enable row level security;
revoke all on public.attendance_login_checks from public,anon,authenticated;
alter table public.property_messages drop constraint if exists property_messages_message_type_check;
alter table public.property_messages add constraint property_messages_message_type_check
 check(message_type in('general','emergency_report','attendance_approval','property_share_approval','announcement','attendance_warning'));
create or replace function public.list_attendance_warning_rules(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_rules jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('rule_id',r.id,'employee_id',r.employee_id,'employee_ids',to_jsonb(r.target_employee_ids),'target_all',r.target_all,'event_type',r.event_type,
    'comparison',r.comparison,'threshold_minutes',r.threshold_minutes,'message',r.message,'active',r.active)
    order by r.created_at,r.id),'[]'::jsonb) into v_rules
  from public.attendance_warning_rules r where r.property_id=v_property_id and r.active;
  return jsonb_build_object('ok',true,'rules',v_rules);
end;
$$;
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
    if (not v_all and cardinality(v_ids)=0) or cardinality(v_ids)>50
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
create or replace function public.evaluate_attendance_warnings(p_access_token uuid,p_report_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_actual timestamptz;v_expected timestamptz;v_scheduled time;v_diff integer;v_rule public.attendance_warning_rules%rowtype;
  v_message_id uuid;v_message_ids jsonb:='[]'::jsonb;v_text text;v_triggered boolean;v_expected_text text;v_actual_text text;
  v_scheduled_minutes integer;v_actual_minutes integer;v_login_date date;v_first_login timestamptz;v_claim uuid;
begin
  if p_report_type not in('login','clock_in','clock_out') then return jsonb_build_object('ok',false,'message','보고 종류를 확인해주세요.'); end if;
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  select * into v_employee from public.employees where id=v_session.employee_id;
  select * into v_property from public.properties where id=v_session.property_id;
  -- Check-in reports never generate arrival warnings.
  if p_report_type='clock_in' then return jsonb_build_object('ok',true,'message_ids',v_message_ids); end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_session.employee_id::text,32));
  if p_report_type='login' then
    v_login_date:=(clock_timestamp() at time zone v_property.timezone)::date;
    select min(s.created_at) into v_first_login from public.work_sessions s
      where s.employee_id=v_session.employee_id and s.property_id=v_session.property_id
      and (s.created_at at time zone v_property.timezone)::date=v_login_date;
    v_first_login:=coalesce(v_first_login,clock_timestamp());
    insert into public.attendance_login_checks(employee_id,property_id,login_date,first_login_at)
      values(v_session.employee_id,v_session.property_id,v_login_date,v_first_login)
      on conflict do nothing returning employee_id into v_claim;
    if v_claim is null then return jsonb_build_object('ok',true,'message_ids',v_message_ids); end if;
  end if;
  for v_rule in select * from public.attendance_warning_rules where property_id=v_session.property_id
    and (target_all or v_session.employee_id=any(target_employee_ids) or employee_id=v_session.employee_id) and active
    and ((p_report_type='login' and event_type='clock_in') or (p_report_type='clock_out' and event_type in('clock_out','work_duration')))
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
      if v_rule.event_type='clock_in' then v_actual:=v_first_login;v_scheduled:=v_employee.scheduled_clock_in;
      else v_actual:=v_session.clock_out_at;v_scheduled:=v_employee.scheduled_clock_out;end if;
      if v_actual is null or v_scheduled is null then continue; end if;
      v_expected:=((case when v_rule.event_type='clock_in' then v_login_date else v_session.work_date end)+v_scheduled+case when v_rule.event_type='clock_out' and v_employee.scheduled_clock_in is not null
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
      values(v_property.business_id,v_property.id,'system',v_text,'normal','attendance_warning') returning id into v_message_id;
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
create or replace function public.mark_property_message_read(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_type text;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s
    join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select m.message_type into v_type from public.property_messages m where m.id=p_message_id and m.property_id=v_property_id;
  if v_type in('announcement','attendance_warning') and v_employee_id is not null then
    return jsonb_build_object('ok',false,'code','acknowledgement_required','message','이름 입력과 이해했음 확인이 필요합니다.');
  end if;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.id=p_message_id and m.property_id=v_property_id
    and((v_owner_id is not null and r.owner_id=v_owner_id)or(v_employee_id is not null and r.employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$$;
create or replace function public.acknowledge_announcement(
  p_access_token uuid,p_message_id uuid,p_employee_name text,p_understood boolean
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_name text;v_recipient_id uuid;
begin
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 확인해주세요.'); end if;
  select display_name into v_name from public.employees where id=v_session.employee_id;
  if not coalesce(p_understood,false) then return jsonb_build_object('ok',false,'code','understanding_required','message','이해했음을 체크해주세요.'); end if;
  if btrim(coalesce(p_employee_name,''))<>v_name then return jsonb_build_object('ok',false,'code','name_mismatch','message','본인 이름을 정확히 입력해주세요.'); end if;
  select r.id into v_recipient_id from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.message_id=p_message_id and r.employee_id=v_session.employee_id and m.message_type in('announcement','attendance_warning');
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','확인할 메세지를 찾을 수 없습니다.'); end if;
  update public.property_message_recipients set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_name=v_name,read_at=coalesce(read_at,clock_timestamp()) where id=v_recipient_id;
  return jsonb_build_object('ok',true,'acknowledged_at',clock_timestamp(),'employee_name',v_name);
end;
$$;
create or replace function public.start_work_session(
  p_employee_id uuid, p_pin text, p_shift text default 'general',
  p_business_code text default 'omg',
  p_property_code text default 'seoul-station'
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_employee public.employees%rowtype;
  v_session public.work_sessions%rowtype;
  v_token uuid := gen_random_uuid();
  v_now timestamptz;
  v_timezone text;
  v_date date;
  v_failures integer;
  v_resumed boolean := false;
  v_warnings jsonb;
begin
  if p_employee_id is null or p_pin is null or p_pin !~ '^[0-9]{6,8}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '직원과 PIN을 확인해주세요.');
  end if;

  select e.* into v_employee from public.employees e
  join public.properties p on p.id = e.property_id and p.business_id = e.business_id
  join public.businesses b on b.id = e.business_id
  where e.id = p_employee_id and e.active and e.pin_hash is not null
    and e.role <> 'owner'
    and b.code = p_business_code and p.code = p_property_code
  for update of e;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '직원과 PIN을 확인해주세요.');
  end if;

  v_now := clock_timestamp();
  if v_employee.login_locked_until > v_now then
    return jsonb_build_object('ok', false, 'code', 'locked',
      'message', 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');
  end if;
  v_failures := case when v_employee.login_locked_until is not null
    then 0 else v_employee.login_failures end;
  if omg_private.pin_matches(p_pin, v_employee.pin_hash) is not true then
    v_failures := v_failures + 1;
    update public.employees set login_failures = v_failures,
      login_locked_until = case when v_failures >= 5
        then v_now + interval '15 minutes' else null end
    where id = v_employee.id;
    return jsonb_build_object('ok', false,
      'code', case when v_failures >= 5 then 'locked' else 'invalid_credentials' end,
      'message', case when v_failures >= 5
        then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.'
        else '직원과 PIN을 확인해주세요.' end);
  end if;
  update public.employees set login_failures = 0, login_locked_until = null
    where id = v_employee.id;

  select p.timezone into v_timezone from public.properties p
    where p.id = v_employee.property_id;
  v_now := clock_timestamp();
  v_date := (v_now at time zone v_timezone)::date;
  select s.* into v_session from public.work_sessions s
  where s.employee_id = v_employee.id and s.status = 'working'
    and s.clock_out_at is null for update;
  if found then
    if v_session.work_date < v_date
       or v_session.clock_in_at < v_now - interval '20 hours' then
      update public.work_sessions set status = 'needs_review', token_expires_at = v_now
        where id = v_session.id;
      v_session.id := null;
    else
      v_resumed := true;
    end if;
  end if;

  if v_session.id is null then
    insert into public.work_sessions
      (business_id, property_id, employee_id, shift, work_date,
       clock_in_at, login_token_hash, token_expires_at)
    values (v_employee.business_id, v_employee.property_id, v_employee.id,
      'general', v_date, v_now, omg_private.token_hash(v_token), v_now + interval '20 hours')
    returning * into v_session;
  else
    update public.work_sessions set login_token_hash = omg_private.token_hash(v_token),
      token_expires_at = least(v_now + interval '20 hours', clock_in_at + interval '20 hours')
    where id = v_session.id returning * into v_session;
  end if;
  v_warnings:=public.evaluate_attendance_warnings(v_token,'login');
  return omg_private.session_result(v_session.id)
    || jsonb_build_object('access_token', v_token, 'resumed', v_resumed,'warning_message_ids',coalesce(v_warnings->'message_ids','[]'::jsonb));
end;
$$;
commit;
select 'attendance login warnings and multiple recipients installed' as migration_status;

