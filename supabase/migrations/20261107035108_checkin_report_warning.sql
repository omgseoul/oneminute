CREATE OR REPLACE FUNCTION public.evaluate_attendance_warnings(p_access_token uuid, p_report_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- Login never generates arrival warnings; only a saved check-in report can do so.
  if p_report_type='login' then return jsonb_build_object('ok',true,'message_ids',v_message_ids); end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_session.employee_id::text,32));
  if p_report_type='clock_in' and v_session.checkin_report_at is null then
    return jsonb_build_object('ok',true,'message_ids',v_message_ids);
  end if;
  for v_rule in select * from public.attendance_warning_rules where property_id=v_session.property_id
    and (target_all or v_session.employee_id=any(target_employee_ids) or employee_id=v_session.employee_id) and active
    and ((p_report_type='clock_in' and event_type='clock_in') or (p_report_type='clock_out' and event_type in('clock_out','work_duration')))
    order by created_at loop
    -- An acknowledged pre-checkout warning must not be delivered again after logout.
    if v_rule.event_type='clock_out' and v_rule.before_checkout and exists(
      select 1 from omg_private.checkout_warning_confirmations c where c.work_session_id=v_session.id and c.rule_id=v_rule.id and c.rule_updated_at=v_rule.updated_at
      and c.confirmed_at>=v_session.checkout_report_at-interval '10 minutes') then continue;end if;
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
$function$;

CREATE OR REPLACE FUNCTION public.save_work_report(p_access_token uuid, p_report_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session public.work_sessions%rowtype;
  v_report public.work_reports%rowtype;
  v_employee_name text;
  v_now timestamptz;
  v_payload jsonb;
  v_existing boolean;
  v_basis text;
  v_effective_clock_in timestamptz;
  v_offset integer;
  v_timezone text;
  v_work_date date;
  v_checkout_warnings jsonb;
  v_arrival_warnings jsonb;
begin
  if p_report_type is null or p_report_type not in ('clock_in', 'clock_out')
     or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 20971520 then
    return jsonb_build_object('ok', false, 'code', 'invalid_report',
      'message', '보고서 형식을 확인해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed') for update of s;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  perform omg_private.process_work_confirmation(v_session.id,clock_timestamp());
  select * into v_session from public.work_sessions where id=v_session.id;
  select r.* into v_report from public.work_reports r
    where r.work_session_id = v_session.id and r.report_type = p_report_type;
  v_existing := found;
  if not v_existing then
    if v_session.status <> 'working' or v_session.clock_out_at is not null then
      return jsonb_build_object('ok', false, 'code', 'session_completed',
        'message', '이미 종료된 근무입니다.');
    end if;
    v_now := clock_timestamp();
    if p_report_type='clock_out' then
      v_checkout_warnings:=omg_private.pending_checkout_warnings(v_session.id,v_now);
      if jsonb_array_length(v_checkout_warnings)>0 then
        return jsonb_build_object('ok',false,'code','checkout_warning_required','warnings',v_checkout_warnings,'message','퇴근 전 경고를 확인해주세요.');
      end if;
    end if;
    select p.clock_in_basis,p.clock_in_report_offset_minutes,p.timezone into v_basis,v_offset,v_timezone from public.properties p where p.id=v_session.property_id;
    if p_report_type='clock_out' and v_basis in('report','nfc') and v_session.checkin_report_at is null then
      return jsonb_build_object('ok',false,'code','checkin_required','message','출근보고를 먼저 제출해주세요.');
    end if;
    v_effective_clock_in := case when p_report_type='clock_in' and v_basis='report' then v_now+make_interval(mins=>v_offset)
      when p_report_type='clock_in' and v_basis='nfc' then coalesce(v_session.nfc_entry_at,v_now) else v_session.clock_in_at end;
    if p_report_type='clock_out' and v_now<v_effective_clock_in then
      return jsonb_build_object('ok',false,'code','before_clock_in','message','설정된 출근시각 이후에 퇴근보고해주세요.');
    end if;
    v_work_date:=case when p_report_type='clock_in' and v_basis in('report','nfc') then (v_effective_clock_in at time zone v_timezone)::date else v_session.work_date end;
    select e.display_name into v_employee_name from public.employees e
      where e.id = v_session.employee_id;
    v_report.id := gen_random_uuid();
    v_payload := (p_payload - 'watch_test_after_minutes' - 'watch_test_requested') || jsonb_build_object(
      'worker', v_employee_name, 'shift', '근무',
      'report_type', case when p_report_type = 'clock_in' then '출근보고' else '퇴근보고' end,
      'report_id', v_report.id, 'work_session_id', v_session.id,
      'work_date', v_work_date, 'attendance_basis',v_basis,'attendance_time_source',case when v_basis='nfc' and v_session.nfc_entry_at is null then 'report_fallback' else v_basis end,'attendance_report_offset_minutes',v_offset,'attendance_nfc_entry_at',v_session.nfc_entry_at, 'attendance_clock_in_at', v_effective_clock_in,
      'submitted_at', v_now
    );
    if p_report_type='clock_in' and jsonb_typeof(v_payload->'text')='string' then
      v_payload:=jsonb_set(v_payload,'{text}',to_jsonb(regexp_replace(v_payload->>'text','출근시각: [^\n]*','출근시각: '||to_char(v_effective_clock_in at time zone v_timezone,'YYYY-MM-DD HH24:MI:SS'))));
    end if;
    insert into public.work_reports
      (id, work_session_id, business_id, property_id, employee_id, report_type, payload, submitted_at)
    values (v_report.id, v_session.id, v_session.business_id, v_session.property_id,
      v_session.employee_id, p_report_type, v_payload, v_now)
    returning * into v_report;
    if p_report_type = 'clock_in' then
      update public.work_sessions set checkin_report_at = v_now,
        first_login_at = coalesce(first_login_at, clock_in_at),
        clock_in_at = v_effective_clock_in,work_date=v_work_date where id = v_session.id;
    else
      update public.work_sessions set checkout_report_at = v_now, clock_out_at = v_now,
        status = 'completed' where id = v_session.id;
    end if;
  end if;
  if p_report_type='clock_in' then v_arrival_warnings:=public.evaluate_attendance_warnings(p_access_token,'clock_in');end if;
  return jsonb_build_object('warning_message_ids',coalesce(v_arrival_warnings->'message_ids','[]'::jsonb),'ok', true, 'report_id', v_report.id,
    'already_saved', v_existing, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$function$;
