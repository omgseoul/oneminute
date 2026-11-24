-- Keep arrival choices private; all reads/writes require a valid work-session RPC.
create table if not exists omg_private.attendance_nfc_entries (
 id uuid primary key default gen_random_uuid(),
 work_session_id uuid not null references public.work_sessions(id) on delete cascade,
 recorded_at timestamptz not null default clock_timestamp(),
 tag_uid text not null,
 selected boolean not null default false
);
create index if not exists attendance_nfc_entries_session_idx on omg_private.attendance_nfc_entries(work_session_id,recorded_at);
create unique index if not exists attendance_nfc_selected_session_idx on omg_private.attendance_nfc_entries(work_session_id) where selected;
alter table omg_private.attendance_nfc_entries enable row level security;
revoke all on omg_private.attendance_nfc_entries from public,anon,authenticated;
insert into omg_private.attendance_nfc_entries(work_session_id,recorded_at,tag_uid)
 select s.id,s.nfc_entry_at,coalesce(s.nfc_tag_uid,'') from public.work_sessions s
 where s.nfc_entry_at is not null and s.checkin_report_at is null and s.status='working'
 and not exists(select 1 from omg_private.attendance_nfc_entries n where n.work_session_id=s.id);

CREATE OR REPLACE FUNCTION public.attendance_nfc_entry(p_access_token uuid, p_tag_uid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
declare s public.work_sessions%rowtype;basis text;offset_minutes int;tags text[];uid text;seen boolean;stamp timestamptz;entries jsonb;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id
 where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp()
 and e.active and w.status in('working','completed') for update of w;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','근무자 로그인이 만료되었습니다.');end if;
 select clock_in_basis,clock_in_report_offset_minutes,attendance_nfc_tags into basis,offset_minutes,tags from public.properties where id=s.property_id;
 seen:=s.nfc_entry_at is not null;
 if p_tag_uid is not null then
  if basis<>'nfc' then return jsonb_build_object('ok',false,'message','이 지점은 NFC 출근을 사용하지 않습니다.');end if;
  if s.status<>'working' or s.clock_out_at is not null then return jsonb_build_object('ok',false,'message','종료된 근무입니다. 다시 로그인해주세요.');end if;
  uid:=omg_private.normalize_attendance_uid(p_tag_uid);
  if uid is null or not coalesce(uid=any(tags),false) then return jsonb_build_object('ok',false,'code','wrong_tag','message','이 지점에 등록된 NFC 태그가 아닙니다.');end if;
  if s.checkin_report_at is not null then return jsonb_build_object('ok',false,'message','이미 출근보고한 근무입니다. 다음 근무부터 적용됩니다.');end if;
  stamp:=clock_timestamp();
  -- Reader-mode callbacks can repeat while the phone still touches the tag.
  if not exists(select 1 from omg_private.attendance_nfc_entries where work_session_id=s.id and tag_uid=uid and recorded_at>stamp-interval '3 seconds') then
   insert into omg_private.attendance_nfc_entries(work_session_id,recorded_at,tag_uid) values(s.id,stamp,uid);
  end if;
  if not seen then update public.work_sessions set nfc_entry_at=stamp,nfc_tag_uid=uid where id=s.id returning * into s;end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'recorded_at',recorded_at) order by recorded_at,id),'[]'::jsonb)
 into entries from omg_private.attendance_nfc_entries where work_session_id=s.id;
 return jsonb_build_object('ok',true,'basis',basis,'report_offset_minutes',offset_minutes,'entry_at',coalesce((select recorded_at from omg_private.attendance_nfc_entries where work_session_id=s.id and selected),s.nfc_entry_at),
 'selected_entry_id',(select id from omg_private.attendance_nfc_entries where work_session_id=s.id and selected),
 'nfc_entries',entries,'already_recorded',seen,'checkin_report_at',s.checkin_report_at,'status',s.status,
 'clock_in_at',s.clock_in_at,'clock_out_at',s.clock_out_at,'unconfirmed_ended_at',s.unconfirmed_ended_at);
end$$;
revoke all on function public.attendance_nfc_entry(uuid,text) from public;
grant execute on function public.attendance_nfc_entry(uuid,text) to anon,authenticated;

-- Choose an arrival when entering the report, without marking the shift checked in.
create or replace function public.attendance_nfc_select(p_access_token uuid,p_entry_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id
 where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active for update of w;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','근무자 로그인이 만료되었습니다.');end if;
 if s.status<>'working' or s.clock_out_at is not null or s.checkin_report_at is not null then return jsonb_build_object('ok',false,'code','session_completed','message','이미 출근보고했거나 종료된 근무입니다.');end if;
 if not exists(select 1 from public.properties where id=s.property_id and clock_in_basis='nfc') then return jsonb_build_object('ok',false,'message','이 지점은 NFC 출근을 사용하지 않습니다.');end if;
 if not exists(select 1 from omg_private.attendance_nfc_entries where id=p_entry_id and work_session_id=s.id and recorded_at<=clock_timestamp()) then return jsonb_build_object('ok',false,'code','invalid_nfc_entry','message','이 근무의 NFC 기록을 선택해주세요.');end if;
 update omg_private.attendance_nfc_entries set selected=false where work_session_id=s.id and selected;
 update omg_private.attendance_nfc_entries set selected=true where id=p_entry_id and work_session_id=s.id;
 return public.attendance_nfc_entry(p_access_token,null);
end$$;
revoke all on function public.attendance_nfc_select(uuid,uuid) from public;
grant execute on function public.attendance_nfc_select(uuid,uuid) to anon,authenticated;

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
  v_nfc_choice omg_private.attendance_nfc_entries%rowtype;
  v_nfc_entries jsonb;
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
    if p_report_type='clock_in' and v_basis='nfc' then
      select coalesce(jsonb_agg(jsonb_build_object('id',id,'recorded_at',recorded_at) order by recorded_at,id),'[]'::jsonb)
        into v_nfc_entries from omg_private.attendance_nfc_entries where work_session_id=v_session.id;
      if jsonb_array_length(v_nfc_entries)=0 then
        return jsonb_build_object('ok',false,'code','nfc_required','message','새로 NFC 태그해주세요. 메인화면에서 출근보고를 다시 눌러주세요.');
      end if;
      select * into v_nfc_choice from omg_private.attendance_nfc_entries where work_session_id=v_session.id and selected and recorded_at<=v_now;
      if not found then
        return jsonb_build_object('ok',false,'code','nfc_selection_required','message','메인화면의 출근보고에서 NFC 시각을 먼저 선택해주세요.');
      end if;
      if v_nfc_choice.id is not null then
        v_session.nfc_entry_at:=v_nfc_choice.recorded_at;v_session.nfc_tag_uid:=v_nfc_choice.tag_uid;
      end if;
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
    v_payload := (p_payload - 'watch_test_after_minutes' - 'watch_test_requested' - 'attendance_nfc_entry_id') || jsonb_build_object(
      'worker', v_employee_name, 'shift', '근무',
      'report_type', case when p_report_type = 'clock_in' then '출근보고' else '퇴근보고' end,
      'report_id', v_report.id, 'work_session_id', v_session.id,
      'attendance_nfc_entry_id',v_nfc_choice.id,'work_date', v_work_date, 'attendance_basis',v_basis,'attendance_time_source',case when v_basis='nfc' and v_session.nfc_entry_at is null then 'report_fallback' else v_basis end,'attendance_report_offset_minutes',v_offset,'attendance_nfc_entry_at',v_session.nfc_entry_at, 'attendance_clock_in_at', v_effective_clock_in,
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
        nfc_entry_at=v_session.nfc_entry_at,nfc_tag_uid=v_session.nfc_tag_uid,
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

CREATE OR REPLACE FUNCTION omg_private.ai_owner(p_token uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;home uuid;rows jsonb;item jsonb;v_mode text;st time;et time;begin
 a:=omg_private.guest_actor(p_token);if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 if nullif(p_data->>'property_id','') is not null then
  home:=(p_data->>'property_id')::uuid;
  if not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) then
   raise exception '이 지점의 AI 설정을 관리할 권한이 없습니다.';
  end if;
 end if;
 insert into omg_private.ai_settings(property_id) values(home) on conflict do nothing;insert into omg_private.ai_wallets(property_id) values(home) on conflict do nothing;
 if p_action='save' then
  rows:=coalesce(p_data->'data','[]');v_mode:=coalesce(p_data->>'mode','always');st:=nullif(p_data->>'start_time','')::time;et:=nullif(p_data->>'end_time','')::time;
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>200 or octet_length(rows::text)>60000 then raise exception 'DATA는 200행, 총 60KB까지 입력할 수 있습니다.';end if;
  if v_mode not in('always','no_staff','schedule') or (v_mode='schedule' and(st is null or et is null or st=et)) then raise exception '사용 조건과 서로 다른 시작·종료 시간을 선택해주세요.';end if;
  if length(btrim(coalesce(p_data->>'prompt',''))) not between 1 and 8000 then raise exception '프롬프트는 1~8,000자로 입력해주세요.';end if;
  for item in select value from jsonb_array_elements(rows) loop if length(btrim(coalesce(item->>'title',''))) not between 1 and 120 or length(coalesce(item->>'answer',''))>4000 then raise exception '제목은 1~120자, 답변은 4,000자 이내로 입력해주세요.';end if;end loop;
  if coalesce((p_data->>'enabled')::boolean,false) and not exists(select 1 from jsonb_array_elements(rows)j where length(btrim(coalesce(j->>'answer','')))>0) then raise exception '자동답변 DATA를 하나 이상 입력해주세요.';end if;
  update omg_private.ai_settings set handoff_config=case when p_data ? 'handoff_config' then omg_private.ai_validate_alert_config(p_data->'handoff_config') else handoff_config end,emergency_config=case when p_data ? 'emergency_config' then omg_private.ai_validate_alert_config(p_data->'emergency_config') else emergency_config end,enabled=coalesce((p_data->>'enabled')::boolean,false),mode=v_mode,start_time=st,end_time=et,prompt=btrim(p_data->>'prompt'),data=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'answer',btrim(j->>'answer'))),'[]') from jsonb_array_elements(rows)j),revision=revision+1,updated_at=now(),updated_by=a->>'key' where property_id=home;
 elsif p_action<>'get' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'settings',(select to_jsonb(s) from omg_private.ai_settings s where property_id=home),'usage',omg_private.ai_summary(home),'default_prompt',omg_private.ai_default_prompt(),'provider_ready',exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null),'qr_enabled',exists(select 1 from public.guest_support_config where property_id=home and enabled and chat_enabled),'timezone',(select timezone from public.properties where id=home),'history',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select created_at,status,charged_micro/1000.0 credits,reason,estimated from omg_private.ai_jobs where property_id=home order by created_at desc limit 30)x));
end$function$
;
