begin;
create table if not exists omg_private.employee_profile_warning_settings(
 property_id uuid primary key references public.properties(id) on delete cascade,
 enabled boolean not null default false,
 updated_at timestamptz not null default now()
);
alter table omg_private.employee_profile_warning_settings enable row level security;
revoke all on omg_private.employee_profile_warning_settings from public,anon,authenticated;

create or replace function public.employee_profile_warning_config(p_access_token uuid,p_property_id uuid,p_enabled boolean default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare enabled_value boolean;
begin
 if not coalesce(omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings'),false) then raise exception '근무자 계정관리 권한이 없습니다.';end if;
 if p_enabled is not null then
  insert into omg_private.employee_profile_warning_settings(property_id,enabled)values(p_property_id,p_enabled)
  on conflict(property_id)do update set enabled=excluded.enabled,updated_at=now();
 end if;
 select enabled into enabled_value from omg_private.employee_profile_warning_settings where property_id=p_property_id;
 return jsonb_build_object('ok',true,'enabled',coalesce(enabled_value,false));
end$$;
revoke all on function public.employee_profile_warning_config(uuid,uuid,boolean) from public;
grant execute on function public.employee_profile_warning_config(uuid,uuid,boolean) to anon,authenticated;

-- Only fields exposed as editable inputs by employee_self_profile.
create or replace function omg_private.employee_profile_missing(eid uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(x.label order by x.ord),'[]'::jsonb)
 from public.employees e join omg_private.employee_profile_warning_settings s on s.property_id=e.property_id and s.enabled
 cross join lateral(values
 (1,'이름',nullif(btrim(e.display_name),'') is null),
 (2,'직무',nullif(btrim(e.job_title),'') is null),
 (3,'연락처',nullif(btrim(e.contact_phone),'') is null),
 (4,'계좌번호',nullif(btrim(e.bank_account),'') is null),
 (5,'출근시간',e.scheduled_clock_in is null),
 (6,'퇴근시간',e.scheduled_clock_out is null),
 (7,'지각 기준',e.lateness_threshold_minutes is null))x(ord,label,missing)
 where e.id=eid and e.active and e.role<>'owner' and x.missing
$$;
revoke all on function omg_private.employee_profile_missing(uuid) from public,anon,authenticated;

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
  return jsonb_build_object('profile_missing',case when p_report_type='clock_in' and not v_existing then omg_private.employee_profile_missing(v_session.employee_id) else '[]'::jsonb end,'warning_message_ids',coalesce(v_arrival_warnings->'message_ids','[]'::jsonb),'ok', true, 'report_id', v_report.id,
    'already_saved', v_existing, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$function$

;
commit;
