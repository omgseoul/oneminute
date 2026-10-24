-- Preserve all existing attendance; settings apply only to a new clock-in report.
alter table public.properties drop constraint properties_clock_in_basis_check;
alter table public.properties add constraint properties_clock_in_basis_check check(clock_in_basis in('first_login','report','nfc'));
alter table public.properties add column clock_in_report_offset_minutes integer not null default 0 check(clock_in_report_offset_minutes between -1440 and 1440);
alter table public.properties add column attendance_nfc_tags text[] not null default '{}' check(cardinality(attendance_nfc_tags)<=10);
alter table public.work_sessions add column nfc_entry_at timestamptz;
alter table public.work_sessions add column nfc_tag_uid text;

create or replace function omg_private.normalize_attendance_uid(p_uid text)
returns text language sql immutable set search_path='' as $$
 select case when v ~ '^([0-9A-F]{8}|[0-9A-F]{14}|[0-9A-F]{16}|[0-9A-F]{20})$' then v else null end
 from (select upper(regexp_replace(coalesce(p_uid,''),'[[:space:]:-]','','g')) v) x;
$$;
revoke all on function omg_private.normalize_attendance_uid(text) from public,anon,authenticated;

-- Use the existing owner session and shared-property authorization contract.
create or replace function public.attendance_clock_in_settings(p_access_token uuid,p_action text,p_property_id uuid default null,p_settings jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property uuid; v_basis text; v_offset integer; v_tags text[]; v_tag text; v_item jsonb;
begin
 select s.property_id into v_property from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','관리자 로그인이 만료되었습니다.'); end if;
 v_property:=coalesce(p_property_id,v_property);
 if not omg_private.can_manage_shared_property(p_access_token,v_property,'property_settings') then
  return jsonb_build_object('ok',false,'code','forbidden','message','숙소 설정 권한이 없습니다.');
 end if;
 if p_action='save' then
  if p_settings is null or jsonb_typeof(p_settings)<>'object' or octet_length(p_settings::text)>4096 then
   return jsonb_build_object('ok',false,'message','근태설정 값을 확인해주세요.');
  end if;
  v_basis:=p_settings->>'basis';
  if v_basis is null or v_basis not in('first_login','report','nfc') then return jsonb_build_object('ok',false,'message','출근시간 기준을 선택해주세요.'); end if;
  if coalesce(p_settings->>'report_offset_minutes','') !~ '^-?[0-9]{1,4}$' then return jsonb_build_object('ok',false,'message','시간 조정은 분 단위 정수로 입력해주세요.'); end if;
  v_offset:=(p_settings->>'report_offset_minutes')::integer;
  if v_offset not between -1440 and 1440 then return jsonb_build_object('ok',false,'message','시간 조정은 -1440~1440분 사이로 입력해주세요.'); end if;
  if jsonb_typeof(p_settings->'nfc_tags') is distinct from 'array' then return jsonb_build_object('ok',false,'message','NFC 태그 값을 확인해주세요.'); end if;
  if jsonb_array_length(p_settings->'nfc_tags')>10 then return jsonb_build_object('ok',false,'message','NFC 태그는 최대 10개까지 등록할 수 있습니다.'); end if;
  v_tags:='{}';
  for v_item in select value from jsonb_array_elements(p_settings->'nfc_tags') loop
   v_tag:=omg_private.normalize_attendance_uid(v_item#>>'{}');
   if jsonb_typeof(v_item)<>'string' or v_tag is null then return jsonb_build_object('ok',false,'message','태그의 고유번호(UID)를 16진수로 입력해주세요.'); end if;
   if not v_tag=any(v_tags) then v_tags:=array_append(v_tags,v_tag);end if;
  end loop;
  if v_basis='nfc' and cardinality(v_tags)=0 then return jsonb_build_object('ok',false,'message','사용할 NFC 태그를 등록해주세요.'); end if;
  update public.properties set clock_in_basis=v_basis,clock_in_report_offset_minutes=v_offset,attendance_nfc_tags=v_tags where id=v_property;
 elsif p_action is distinct from 'get' then return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');end if;
 select clock_in_basis,clock_in_report_offset_minutes,attendance_nfc_tags into v_basis,v_offset,v_tags from public.properties where id=v_property;
 return jsonb_build_object('ok',true,'basis',v_basis,'report_offset_minutes',v_offset,'nfc_tags',v_tags);
end $$;
revoke all on function public.attendance_clock_in_settings(uuid,text,uuid,jsonb) from public;
grant execute on function public.attendance_clock_in_settings(uuid,text,uuid,jsonb) to anon,authenticated;

-- The work-session row is the shift boundary. Concurrent/repeated reads keep its first entry.
-- Do not accept a caller-supplied employee, branch, or timestamp.
create or replace function public.attendance_nfc_entry(p_access_token uuid,p_tag_uid text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_basis text;v_offset integer;v_tags text[];v_uid text;v_seen boolean;
begin
 select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active
 and s.status in('working','completed') for update of s;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','근무자 로그인이 만료되었습니다.');end if;
 select clock_in_basis,clock_in_report_offset_minutes,attendance_nfc_tags into v_basis,v_offset,v_tags from public.properties where id=v_session.property_id;
 v_seen:=v_session.nfc_entry_at is not null;
 if p_tag_uid is not null then
  if v_basis<>'nfc' then return jsonb_build_object('ok',false,'message','이 지점은 NFC 출근을 사용하지 않습니다.');end if;
  if v_session.status<>'working' or v_session.clock_out_at is not null then return jsonb_build_object('ok',false,'message','종료된 근무입니다. 다시 로그인해주세요.');end if;
  v_uid:=omg_private.normalize_attendance_uid(p_tag_uid);
  if v_uid is null or not v_uid=any(v_tags) then return jsonb_build_object('ok',false,'code','wrong_tag','message','이 지점에 등록된 NFC 태그가 아닙니다.');end if;
  if v_session.checkin_report_at is not null and not v_seen then return jsonb_build_object('ok',false,'message','이미 출근보고한 근무입니다. 다음 근무부터 적용됩니다.');end if;
  if not v_seen then
   update public.work_sessions set nfc_entry_at=clock_timestamp(),nfc_tag_uid=v_uid where id=v_session.id returning * into v_session;
  end if;
 end if;
 return jsonb_build_object('ok',true,'basis',v_basis,'report_offset_minutes',v_offset,'entry_at',v_session.nfc_entry_at,
  'already_recorded',v_seen,'checkin_report_at',v_session.checkin_report_at,'status',v_session.status,'clock_in_at',v_session.clock_in_at);
end $$;
revoke all on function public.attendance_nfc_entry(uuid,text) from public;
grant execute on function public.attendance_nfc_entry(uuid,text) to anon,authenticated;

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
  select r.* into v_report from public.work_reports r
    where r.work_session_id = v_session.id and r.report_type = p_report_type;
  v_existing := found;
  if not v_existing then
    if v_session.status <> 'working' or v_session.clock_out_at is not null then
      return jsonb_build_object('ok', false, 'code', 'session_completed',
        'message', '이미 종료된 근무입니다.');
    end if;
    v_now := clock_timestamp();
    select p.clock_in_basis,p.clock_in_report_offset_minutes,p.timezone into v_basis,v_offset,v_timezone from public.properties p where p.id=v_session.property_id;
    if p_report_type='clock_out' and v_basis in('report','nfc') and v_session.checkin_report_at is null then
      return jsonb_build_object('ok',false,'code','checkin_required','message','출근보고를 먼저 제출해주세요.');
    end if;
    if p_report_type='clock_in' and v_basis='nfc' and v_session.nfc_entry_at is null then
      return jsonb_build_object('ok',false,'code','nfc_required','message','현장 NFC 태그로 입장을 확인한 뒤 출근보고해주세요.');
    end if;
    v_effective_clock_in := case when p_report_type='clock_in' and v_basis='report' then v_now+make_interval(mins=>v_offset)
      when p_report_type='clock_in' and v_basis='nfc' then v_session.nfc_entry_at else v_session.clock_in_at end;
    if p_report_type='clock_out' and v_now<v_effective_clock_in then
      return jsonb_build_object('ok',false,'code','before_clock_in','message','설정된 출근시각 이후에 퇴근보고해주세요.');
    end if;
    v_work_date:=case when p_report_type='clock_in' and v_basis in('report','nfc') then (v_effective_clock_in at time zone v_timezone)::date else v_session.work_date end;
    select e.display_name into v_employee_name from public.employees e
      where e.id = v_session.employee_id;
    v_report.id := gen_random_uuid();
    v_payload := p_payload || jsonb_build_object(
      'worker', v_employee_name, 'shift', '근무',
      'report_type', case when p_report_type = 'clock_in' then '출근보고' else '퇴근보고' end,
      'report_id', v_report.id, 'work_session_id', v_session.id,
      'work_date', v_work_date, 'attendance_basis',v_basis,'attendance_report_offset_minutes',v_offset,'attendance_nfc_entry_at',v_session.nfc_entry_at, 'attendance_clock_in_at', v_effective_clock_in,
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
