-- Resolve the recurring scheduled shift containing the checkout attempt.
-- Until the next scheduled start, a late/overnight checkout still belongs to the prior shift.
-- This is only a warning reference; recorded work dates/times and payroll are never changed.
create or replace function omg_private.checkout_warning_expected_at(p_work_date date,p_start time,p_end time,p_timezone text,p_actual timestamptz)
returns timestamptz language sql stable set search_path='' as $$
 select (greatest(p_work_date,case when p_start is null then p_work_date
   else (p_actual at time zone p_timezone)::date-case when (p_actual at time zone p_timezone)::time<p_start then 1 else 0 end end)
   +p_end+case when p_start is not null and p_end<=p_start then interval '1 day' else interval '0' end) at time zone p_timezone
$$;
revoke all on function omg_private.checkout_warning_expected_at(date,time,time,text,timestamptz) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION omg_private.pending_checkout_warnings(p_session_id uuid, p_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.work_sessions%rowtype;e public.employees%rowtype;p public.properties%rowtype;
 r public.attendance_warning_rules%rowtype; expected timestamptz;diff integer;result jsonb:='[]';body text;
begin
 select * into s from public.work_sessions where id=p_session_id;
 if not found or s.status<>'working' or s.clock_out_at is not null then return result;end if;
 select * into e from public.employees where id=s.employee_id;
 select * into p from public.properties where id=s.property_id;
 if e.scheduled_clock_out is null then return result;end if;
 expected:=omg_private.checkout_warning_expected_at(s.work_date,e.scheduled_clock_in,e.scheduled_clock_out,p.timezone,p_now);
 diff:=trunc(extract(epoch from(p_now-expected))/60)::integer;
 for r in select * from public.attendance_warning_rules where property_id=s.property_id and active and event_type='clock_out' and before_checkout
  and(target_all or s.employee_id=any(target_employee_ids) or employee_id=s.employee_id) order by created_at,id loop
  if ((r.comparison='late' and diff>=r.threshold_minutes) or(r.comparison='early' and diff<=-r.threshold_minutes) or(r.comparison='both' and abs(diff)>=r.threshold_minutes))
   and not exists(select 1 from omg_private.checkout_warning_confirmations c where c.work_session_id=s.id and c.rule_id=r.id and c.rule_updated_at=r.updated_at and c.confirmed_at>=p_now-interval '10 minutes') then
   body:=replace(replace(replace(replace(r.message,'{이름}',e.display_name),'{예정시간}',to_char(expected at time zone p.timezone,'HH24:MI')),'{실제시간}',to_char(p_now at time zone p.timezone,'HH24:MI')),'{차이분}',abs(diff)::text);
   result:=result||jsonb_build_array(jsonb_build_object('rule_id',r.id,'rule_updated_at',r.updated_at,'message',body,'expected_at',expected,'actual_at',p_now,'timezone',p.timezone));
  end if;
 end loop;
 return result;
end $function$

;

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
      if v_rule.event_type='clock_out' then
        v_expected:=omg_private.checkout_warning_expected_at(v_session.work_date,v_employee.scheduled_clock_in,v_scheduled,v_property.timezone,v_actual);
        v_diff:=trunc(extract(epoch from(v_actual-v_expected))/60)::integer;
      else
        v_expected:=(v_session.work_date+v_scheduled) at time zone v_property.timezone;
        v_diff:=floor(extract(epoch from(v_actual-v_expected))/60)::integer;
      end if;
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
$function$

;
