-- Acknowledgement happens before the checkout timestamp/report is committed.
alter table public.attendance_warning_rules add column if not exists before_checkout boolean not null default false;
update public.attendance_warning_rules set before_checkout=true where event_type='clock_out';
create table omg_private.checkout_warning_confirmations (
 work_session_id uuid not null references public.work_sessions(id) on delete cascade,
 rule_id uuid not null references public.attendance_warning_rules(id) on delete cascade,
 rule_updated_at timestamptz not null, confirmed_at timestamptz not null default clock_timestamp(),
 primary key(work_session_id,rule_id)
);
alter table omg_private.checkout_warning_confirmations enable row level security;
revoke all on omg_private.checkout_warning_confirmations from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.list_attendance_warning_rules(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_rules jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('rule_id',r.id,'employee_id',r.employee_id,'employee_ids',to_jsonb(r.target_employee_ids),'target_all',r.target_all,'event_type',r.event_type,
    'comparison',r.comparison,'threshold_minutes',r.threshold_minutes,'message',r.message,'active',r.active,'before_checkout',r.before_checkout)
    order by r.created_at,r.id),'[]'::jsonb) into v_rules
  from public.attendance_warning_rules r where r.property_id=v_property_id and r.active;
  return jsonb_build_object('ok',true,'rules',v_rules);
end;
$function$;
CREATE OR REPLACE FUNCTION public.shared_list_attendance_warning_rules(p_access_token uuid, p_property_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_rules jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select coalesce(jsonb_agg(jsonb_build_object('rule_id',r.id,'employee_id',r.employee_id,'employee_ids',to_jsonb(r.target_employee_ids),'target_all',r.target_all,'event_type',r.event_type,
    'comparison',r.comparison,'threshold_minutes',r.threshold_minutes,'message',r.message,'active',r.active,'before_checkout',r.before_checkout)
    order by r.created_at,r.id),'[]'::jsonb) into v_rules
  from public.attendance_warning_rules r where r.property_id=v_property_id and r.active;
  return jsonb_build_object('ok',true,'rules',v_rules);
end;
$function$;
CREATE OR REPLACE FUNCTION public.save_attendance_warning_rules(p_access_token uuid, p_rules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      insert into public.attendance_warning_rules(business_id,property_id,employee_id,target_employee_ids,target_all,event_type,comparison,threshold_minutes,message,active,before_checkout)
      values(v_business_id,v_property_id,null,v_ids,v_all,v_event,v_comparison,v_minutes,v_message,v_active,(v_event='clock_out' and coalesce((v_item->>'before_checkout')::boolean,true))) returning id into v_rule_id;
    else
      update public.attendance_warning_rules set employee_id=null,target_employee_ids=v_ids,target_all=v_all,event_type=v_event,comparison=v_comparison,
        threshold_minutes=v_minutes,message=v_message,active=v_active,before_checkout=(v_event='clock_out' and coalesce((v_item->>'before_checkout')::boolean,true)),updated_at=clock_timestamp()
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
$function$;
CREATE OR REPLACE FUNCTION public.shared_save_attendance_warning_rules(p_access_token uuid, p_property_id uuid, p_rules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_business_id uuid;v_property_id uuid;v_item jsonb;v_rule_id uuid;v_ids uuid[];v_all boolean;
  v_event text;v_comparison text;v_minutes integer;v_message text;v_active boolean;v_keep uuid[]:='{}';
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings') then return jsonb_build_object('ok',false,'message','공유 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  select business_id into v_business_id from public.properties where id=p_property_id;
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
      insert into public.attendance_warning_rules(business_id,property_id,employee_id,target_employee_ids,target_all,event_type,comparison,threshold_minutes,message,active,before_checkout)
      values(v_business_id,v_property_id,null,v_ids,v_all,v_event,v_comparison,v_minutes,v_message,v_active,(v_event='clock_out' and coalesce((v_item->>'before_checkout')::boolean,true))) returning id into v_rule_id;
    else
      update public.attendance_warning_rules set employee_id=null,target_employee_ids=v_ids,target_all=v_all,event_type=v_event,comparison=v_comparison,
        threshold_minutes=v_minutes,message=v_message,active=v_active,before_checkout=(v_event='clock_out' and coalesce((v_item->>'before_checkout')::boolean,true)),updated_at=clock_timestamp()
        where id=v_rule_id and property_id=v_property_id;
      if not found then raise exception '수정할 워닝 조건을 찾지 못했습니다.'; end if;
    end if;
    v_keep:=array_append(v_keep,v_rule_id);
  end loop;
  -- Archive omitted rules to retain delivery history.
  update public.attendance_warning_rules set active=false where property_id=v_property_id and not(id=any(v_keep));
  return public.shared_list_attendance_warning_rules(p_access_token,p_property_id);
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok',false,'code','invalid_rule','message',case when SQLSTATE='P0001' then SQLERRM else '근무시간 워닝 입력값을 확인해주세요.' end);
end;
$function$;

create or replace function omg_private.pending_checkout_warnings(p_session_id uuid,p_now timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;e public.employees%rowtype;p public.properties%rowtype;
 r public.attendance_warning_rules%rowtype; expected timestamptz;diff integer;result jsonb:='[]';body text;
begin
 select * into s from public.work_sessions where id=p_session_id;
 if not found or s.status<>'working' or s.clock_out_at is not null then return result;end if;
 select * into e from public.employees where id=s.employee_id;
 select * into p from public.properties where id=s.property_id;
 if e.scheduled_clock_out is null then return result;end if;
 expected:=(s.work_date+e.scheduled_clock_out+case when e.scheduled_clock_in is not null and e.scheduled_clock_out<=e.scheduled_clock_in then interval '1 day' else interval '0' end) at time zone p.timezone;
 diff:=floor(extract(epoch from(p_now-expected))/60)::integer;
 for r in select * from public.attendance_warning_rules where property_id=s.property_id and active and event_type='clock_out' and before_checkout
  and(target_all or s.employee_id=any(target_employee_ids) or employee_id=s.employee_id) order by created_at,id loop
  if ((r.comparison='late' and diff>=r.threshold_minutes) or(r.comparison='early' and diff<=-r.threshold_minutes) or(r.comparison='both' and abs(diff)>=r.threshold_minutes))
   and not exists(select 1 from omg_private.checkout_warning_confirmations c where c.work_session_id=s.id and c.rule_id=r.id and c.rule_updated_at=r.updated_at and c.confirmed_at>=p_now-interval '10 minutes') then
   body:=replace(replace(replace(replace(r.message,'{이름}',e.display_name),'{예정시간}',to_char(expected at time zone p.timezone,'HH24:MI')),'{실제시간}',to_char(p_now at time zone p.timezone,'HH24:MI')),'{차이분}',abs(diff)::text);
   result:=result||jsonb_build_array(jsonb_build_object('rule_id',r.id,'rule_updated_at',r.updated_at,'message',body));
  end if;
 end loop;
 return result;
end $$;
revoke all on function omg_private.pending_checkout_warnings(uuid,timestamptz) from public,anon,authenticated;
create or replace function public.preview_checkout_warnings(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active and w.status='working';
 if not found then return jsonb_build_object('ok',false,'message','로그인과 근무 상태를 확인해주세요.');end if;
 return jsonb_build_object('ok',true,'warnings',omg_private.pending_checkout_warnings(s.id,clock_timestamp()));
end $$;
create or replace function public.confirm_checkout_warning(p_access_token uuid,p_rule_id uuid,p_rule_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;pending jsonb;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active and w.status='working' for update of w;
 if not found then return jsonb_build_object('ok',false,'message','로그인과 근무 상태를 확인해주세요.');end if;
 pending:=omg_private.pending_checkout_warnings(s.id,clock_timestamp());
 if not exists(select 1 from jsonb_array_elements(pending) x where (x->>'rule_id')::uuid=p_rule_id and (x->>'rule_updated_at')::timestamptz=p_rule_updated_at) then
  return jsonb_build_object('ok',false,'message','경고 조건이 변경되었습니다. 퇴근보고를 다시 눌러주세요.');
 end if;
 insert into omg_private.checkout_warning_confirmations(work_session_id,rule_id,rule_updated_at) values(s.id,p_rule_id,p_rule_updated_at)
 on conflict(work_session_id,rule_id) do update set rule_updated_at=excluded.rule_updated_at,confirmed_at=clock_timestamp();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.preview_checkout_warnings(uuid),public.confirm_checkout_warning(uuid,uuid,timestamptz) from public;
grant execute on function public.preview_checkout_warnings(uuid),public.confirm_checkout_warning(uuid,uuid,timestamptz) to anon,authenticated;
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
  return jsonb_build_object('ok', true, 'report_id', v_report.id,
    'already_saved', v_existing, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$function$;
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
$function$;
CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders_at(p_now timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE s record;r record;i record;ev record;v_date date;v_overdue boolean;v_offset integer;v_time time;v_key text;
 v_message uuid;v_count integer:=0;v_secret text;v_checkin boolean;
BEGIN
 IF NOT pg_try_advisory_xact_lock(20261105,1105) THEN RETURN 0; END IF;
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 FOR s IN SELECT rs.*,p.business_id,coalesce(p.timezone,'Asia/Seoul') tz,
   (p_now AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'))::date today
  FROM public.property_reminder_settings rs JOIN public.properties p ON p.id=rs.property_id
  WHERE jsonb_array_length(rs.schedules)>0 AND (rs.notify_staff OR rs.notify_owner)
 LOOP
  FOR r IN SELECT (x->>'offset_days')::int offset_days,(x->>'send_time')::time send_time,
   coalesce(x->>'trigger','time') trigger,coalesce((x->>'repeat_overdue')::boolean,false) repeat_overdue,
   (x->>'enabled_at')::timestamptz enabled_at FROM jsonb_array_elements(s.schedules) x
   WHERE x->>'trigger'='checkin' OR to_char(p_now AT TIME ZONE s.tz,'HH24:MI')=x->>'send_time'
  LOOP
   v_checkin:=r.trigger='checkin';v_time:=CASE WHEN v_checkin THEN '00:00'::time ELSE r.send_time END;
   FOR i IN
    SELECT 'todo'::text kind,m.id,m.title,m.due_at,m.target_employee_ids targets
     FROM public.missions m WHERE s.kind='todo' AND m.property_id=s.property_id AND m.active AND m.owner_completed_at IS NULL AND m.due_at IS NOT NULL
      AND ((m.due_at AT TIME ZONE s.tz)::date BETWEEN s.today AND s.today+r.offset_days OR (r.repeat_overdue AND (m.due_at AT TIME ZONE s.tz)::date<s.today))
      AND NOT (m.completion_mode='any' AND EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=m.id))
      AND NOT (EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=s.property_id AND e.active AND e.role<>'owner'
        AND (jsonb_array_length(coalesce(m.target_employee_ids,'[]'))=0 OR to_jsonb(e.id)<@m.target_employee_ids))
       AND NOT EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=s.property_id AND e.active AND e.role<>'owner'
        AND (jsonb_array_length(coalesce(m.target_employee_ids,'[]'))=0 OR to_jsonb(e.id)<@m.target_employee_ids)
        AND NOT EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=m.id AND c.employee_id=e.id)))
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids) FROM public.calendar_events c
     WHERE s.kind='calendar' AND c.property_id=s.property_id AND c.holiday_request_id IS NULL
      AND (c.start_at AT TIME ZONE s.tz)::date BETWEEN s.today AND s.today+r.offset_days
   LOOP
    v_date:=(i.due_at AT TIME ZONE s.tz)::date;v_overdue:=i.kind='todo' AND v_date<s.today;
    -- Overdue rules with different offsets but the same time coalesce to one daily reminder.
    v_offset:=CASE WHEN v_overdue THEN -1 ELSE -2 END;
    FOR ev IN
     SELECT NULL::uuid employee_id WHERE NOT v_checkin
     UNION ALL
     SELECT DISTINCT w.employee_id FROM public.work_sessions w JOIN public.employees e ON e.id=w.employee_id AND e.property_id=w.property_id
      WHERE v_checkin AND w.property_id=s.property_id AND e.active AND e.role<>'owner'
       AND w.checkin_report_at>=coalesce(r.enabled_at,p_now) AND w.checkin_report_at<=p_now
       AND w.checkin_report_at>=(s.today::timestamp AT TIME ZONE s.tz)
       AND w.clock_out_at IS NULL AND w.checkout_report_at IS NULL AND w.status='working'
       AND ((i.kind='todo' AND jsonb_array_length(coalesce(i.targets,'[]'))=0) OR to_jsonb(e.id)<@i.targets
        OR (s.notify_owner AND jsonb_array_length(coalesce(i.targets,'[]'))=0))
       AND (i.kind<>'todo' OR NOT EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=i.id AND c.employee_id=e.id))
    LOOP
     v_key:=CASE WHEN v_checkin THEN 'checkin:'||s.today||':'||ev.employee_id WHEN v_overdue THEN 'overdue:'||s.today ELSE 'daily:'||s.today END;
     -- Preserve deliveries made earlier today by the pre-window scheduler.
     IF EXISTS(SELECT 1 FROM public.reminder_deliveries d WHERE d.kind=i.kind AND d.item_id=i.id AND d.send_time=v_time
       AND d.offset_days>=0 AND ((d.delivery_key='' AND (d.created_at AT TIME ZONE s.tz)::date=s.today)
         OR (v_checkin AND d.delivery_key=v_key))) THEN CONTINUE; END IF;
     INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time,delivery_key)
      VALUES(i.kind,i.id,v_offset,v_time,v_key) ON CONFLICT DO NOTHING;
     IF NOT FOUND THEN CONTINUE; END IF;
     INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
      VALUES(s.business_id,s.property_id,'system',CASE WHEN i.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END||E'\n'||
       CASE WHEN v_overdue THEN (s.today-v_date)||'일 지연: ' WHEN v_date=s.today THEN '오늘: ' WHEN v_date=s.today+1 THEN '내일: ' ELSE (v_date-s.today)||'일 후: ' END||left(i.title,120)||E'\n'||CASE WHEN i.kind='todo' THEN '마감: ' ELSE '일정: ' END||to_char(i.due_at AT TIME ZONE s.tz,'YYYY-MM-DD HH24:MI')||E'\n시간대: '||s.tz,
       'normal','general','reminder') RETURNING id INTO v_message;
     IF s.notify_staff THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
       SELECT v_message,'employee:'||e.id,'staff',e.id FROM public.employees e
        WHERE e.property_id=s.property_id AND e.active AND e.role<>'owner' AND (NOT v_checkin OR e.id=ev.employee_id)
         AND ((i.kind='todo' AND jsonb_array_length(coalesce(i.targets,'[]'))=0) OR to_jsonb(e.id)<@i.targets)
         AND (i.kind<>'todo' OR NOT EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=i.id AND c.employee_id=e.id))
       ON CONFLICT DO NOTHING;
     END IF;
     IF s.notify_owner THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
       SELECT v_message,'owner:'||o.id,'owner',o.id FROM public.owners o WHERE o.property_id=s.property_id AND o.active
        AND (NOT v_checkin OR NOT EXISTS(SELECT 1 FROM public.reminder_deliveries d JOIN public.property_message_recipients pr ON pr.message_id=d.message_id
         WHERE d.kind=i.kind AND d.item_id=i.id AND d.offset_days=v_offset AND d.send_time=v_time
          AND d.delivery_key LIKE 'checkin:'||s.today||':%' AND pr.owner_id=o.id))
       ON CONFLICT DO NOTHING;
     END IF;
     IF NOT EXISTS(SELECT 1 FROM public.property_message_recipients WHERE message_id=v_message) THEN
      DELETE FROM public.property_messages WHERE id=v_message;CONTINUE;
     END IF;
     UPDATE public.reminder_deliveries SET message_id=v_message WHERE kind=i.kind AND item_id=i.id AND offset_days=v_offset AND send_time=v_time AND delivery_key=v_key;
     PERFORM net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder',
      headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message));
     v_count:=v_count+1;
    END LOOP;
   END LOOP;
  END LOOP;
 END LOOP;
 RETURN v_count;
END $function$;

create or replace function omg_private.reminder_popup_text(p_kind text,p_title text,p_due timestamptz,p_tz text,p_now timestamptz)
returns text language sql stable set search_path='' as $$
 select (case when p_kind='todo' then 'To do 알림' else '일정 알림' end)||E'\n'||
 (case when p_due is null then '등록: ' when (p_due at time zone p_tz)::date<(p_now at time zone p_tz)::date then ((p_now at time zone p_tz)::date-(p_due at time zone p_tz)::date)||'일 지연: '
 when (p_due at time zone p_tz)::date=(p_now at time zone p_tz)::date then '오늘: ' else ((p_due at time zone p_tz)::date-(p_now at time zone p_tz)::date)||'일 후: ' end)||left(p_title,120)||
 case when p_due is null then '' else E'\n'||case when p_kind='todo' then '마감: ' else '일정: ' end||to_char(p_due at time zone p_tz,'YYYY-MM-DD HH24:MI')||E'\n시간대: '||p_tz end;
$$;
revoke all on function omg_private.reminder_popup_text(text,text,timestamptz,text,timestamptz) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION omg_private.notify_registered_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_kind text;v_targets jsonb;v_message uuid;v_secret text;v_business uuid;v_due timestamptz;v_tz text;v_days integer;
BEGIN
 IF TG_TABLE_NAME='missions' THEN
  IF NOT NEW.active OR NEW.owner_completed_at IS NOT NULL THEN RETURN NEW; END IF;
  v_due:=NEW.due_at;v_kind:='todo';v_targets:=coalesce(NEW.target_employee_ids,'[]'::jsonb);
 ELSE
  IF NEW.holiday_request_id IS NOT NULL THEN RETURN NEW; END IF;
  v_due:=NEW.start_at;v_kind:='calendar';v_targets:=coalesce(to_jsonb(NEW.target_employee_ids),'[]'::jsonb);
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=NEW.property_id AND e.active AND e.role<>'owner'
  AND ((v_kind='todo' AND jsonb_array_length(v_targets)=0) OR to_jsonb(e.id)<@v_targets)) THEN RETURN NEW; END IF;
 INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time,delivery_key)
 VALUES(v_kind,NEW.id,-3,'00:00','created') ON CONFLICT DO NOTHING;
 IF NOT FOUND THEN RETURN NEW; END IF;
 SELECT business_id,timezone INTO v_business,v_tz FROM public.properties WHERE id=NEW.property_id;
 INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
 VALUES(v_business,NEW.property_id,'system',omg_private.reminder_popup_text(v_kind,NEW.title,v_due,v_tz,clock_timestamp()),'normal','general','reminder') RETURNING id INTO v_message;
 INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
 SELECT v_message,'employee:'||e.id,'staff',e.id FROM public.employees e WHERE e.property_id=NEW.property_id AND e.active AND e.role<>'owner'
 AND ((v_kind='todo' AND jsonb_array_length(v_targets)=0) OR to_jsonb(e.id)<@v_targets) ON CONFLICT DO NOTHING;
 UPDATE public.reminder_deliveries SET message_id=v_message WHERE kind=v_kind AND item_id=NEW.id AND delivery_key='created';
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 PERFORM net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder',
 headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message));
 RETURN NEW;
END $function$;

-- Enrich existing reminder bodies linked to their original assignment; IDs/receipts stay intact.
update public.property_messages msg set message=omg_private.reminder_popup_text('todo',m.title,m.due_at,p.timezone,clock_timestamp())
from public.reminder_deliveries d join public.missions m on d.kind='todo' and m.id=d.item_id join public.properties p on p.id=m.property_id
where msg.id=d.message_id and exists(select 1 from public.property_message_recipients r where r.message_id=msg.id and r.read_at is null) and msg.source='reminder' and msg.message like 'To do 알림%' and m.due_at is not null;
update public.property_messages msg set message=omg_private.reminder_popup_text('calendar',c.title,c.start_at,p.timezone,clock_timestamp())
from public.reminder_deliveries d join public.calendar_events c on d.kind='calendar' and c.id=d.item_id join public.properties p on p.id=c.property_id
where msg.id=d.message_id and exists(select 1 from public.property_message_recipients r where r.message_id=msg.id and r.read_at is null) and msg.source='reminder' and msg.message like '일정 알림%';
