-- Working presence can end without inventing a payroll checkout or logging out.
ALTER TABLE public.work_sessions ADD COLUMN next_confirmation_at timestamptz;
ALTER TABLE public.work_sessions ADD COLUMN unconfirmed_ended_at timestamptz;
CREATE INDEX work_confirmation_due_idx ON public.work_sessions(next_confirmation_at)
 WHERE status='working' AND checkin_report_at IS NOT NULL AND clock_out_at IS NULL;
CREATE TABLE omg_private.work_confirmations(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 work_session_id uuid NOT NULL REFERENCES public.work_sessions(id),
 due_at timestamptz NOT NULL, requested_at timestamptz NOT NULL,
 deadline_at timestamptz NOT NULL, confirmed_at timestamptz, ended_at timestamptz, cancelled_at timestamptz,
 UNIQUE(work_session_id,due_at), CHECK(deadline_at=requested_at+interval '10 minutes')
);
ALTER TABLE omg_private.work_confirmations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON omg_private.work_confirmations FROM PUBLIC,anon,authenticated;

CREATE FUNCTION omg_private.work_confirmation_session_hook() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF OLD.checkin_report_at IS NULL AND NEW.checkin_report_at IS NOT NULL AND NEW.status='working' THEN
  NEW.next_confirmation_at:=NEW.checkin_report_at+interval '12 hours';
  NEW.token_expires_at:='infinity'::timestamptz;
 END IF;
 IF OLD.status='working' AND NEW.status<>'working' THEN
  NEW.next_confirmation_at:=NULL;
  UPDATE omg_private.work_confirmations SET cancelled_at=clock_timestamp()
   WHERE work_session_id=NEW.id AND confirmed_at IS NULL AND ended_at IS NULL AND cancelled_at IS NULL;
  UPDATE public.property_message_recipients r SET read_at=coalesce(r.read_at,clock_timestamp())
   FROM omg_private.work_confirmations c WHERE c.work_session_id=NEW.id AND r.message_id=c.id;
 END IF;
 IF NEW.token_expires_at IS DISTINCT FROM OLD.token_expires_at THEN
  UPDATE public.native_push_devices SET expires_at=NEW.token_expires_at WHERE session_hash=NEW.login_token_hash;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION omg_private.work_confirmation_session_hook() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER work_confirmation_session_hook BEFORE UPDATE ON public.work_sessions
 FOR EACH ROW EXECUTE FUNCTION omg_private.work_confirmation_session_hook();

CREATE FUNCTION omg_private.process_work_confirmation(p_session_id uuid,p_now timestamptz) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.work_sessions%rowtype;c omg_private.work_confirmations%rowtype;
BEGIN
 SELECT * INTO s FROM public.work_sessions WHERE id=p_session_id FOR UPDATE;
 IF NOT FOUND OR s.status<>'working' OR s.clock_out_at IS NOT NULL OR s.checkin_report_at IS NULL
  OR s.next_confirmation_at IS NULL OR s.next_confirmation_at>p_now THEN RETURN; END IF;
 SELECT * INTO c FROM omg_private.work_confirmations WHERE work_session_id=s.id AND due_at=s.next_confirmation_at;
 IF NOT FOUND THEN
  INSERT INTO omg_private.work_confirmations(work_session_id,due_at,requested_at,deadline_at)
   VALUES(s.id,s.next_confirmation_at,p_now,p_now+interval '10 minutes') RETURNING * INTO c;
  INSERT INTO public.property_messages(id,business_id,property_id,sender_type,message,priority,message_type,source)
   VALUES(c.id,s.business_id,s.property_id,'system',E'근무 12시간 초과 알림\n근무중인 경우 아래의 버튼을 눌러주십시오.\n10분 안에 누르지 않으면 퇴근 처리되며, 이후 별도로 수정하여 주십시오.','normal','general','work_confirmation');
  INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
   VALUES(c.id,'employee:'||s.employee_id,'staff',s.employee_id);
  INSERT INTO omg_private.chat_push_outbox(message_id) VALUES(c.id) ON CONFLICT DO NOTHING;
  PERFORM omg_private.dispatch_chat_push(c.id);
 ELSIF c.confirmed_at IS NULL AND c.ended_at IS NULL AND c.cancelled_at IS NULL AND c.deadline_at<=p_now THEN
  UPDATE omg_private.work_confirmations SET ended_at=c.deadline_at WHERE id=c.id;
  -- Deliberately leave both payroll/report checkout timestamps NULL.
  UPDATE public.work_sessions SET status='completed',unconfirmed_ended_at=c.deadline_at,next_confirmation_at=NULL WHERE id=s.id;
 END IF;
END $$;
REVOKE ALL ON FUNCTION omg_private.process_work_confirmation(uuid,timestamptz) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION omg_private.process_work_confirmations() RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s record;n integer:=0;
BEGIN
 FOR s IN SELECT w.id FROM public.work_sessions w JOIN public.employees e ON e.id=w.employee_id
  WHERE e.active AND w.status='working' AND w.checkin_report_at IS NOT NULL AND w.clock_out_at IS NULL
   AND w.next_confirmation_at<=clock_timestamp() ORDER BY w.next_confirmation_at LIMIT 200 FOR UPDATE OF w SKIP LOCKED
 LOOP PERFORM omg_private.process_work_confirmation(s.id,clock_timestamp());n:=n+1; END LOOP;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION omg_private.process_work_confirmations() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.work_shift_confirmation(p_access_token uuid,p_confirmation_id uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.work_sessions%rowtype;c omg_private.work_confirmations%rowtype;t timestamptz;accepted boolean:=false;
BEGIN
 SELECT w.* INTO s FROM public.work_sessions w JOIN public.employees e ON e.id=w.employee_id
  WHERE w.login_token_hash=omg_private.token_hash(p_access_token) AND w.token_expires_at>clock_timestamp()
   AND e.active AND w.status IN('working','completed') FOR UPDATE OF w;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','invalid_session');END IF;
 t:=clock_timestamp();PERFORM omg_private.process_work_confirmation(s.id,t);
 SELECT * INTO s FROM public.work_sessions WHERE id=s.id;
 IF p_confirmation_id IS NOT NULL THEN
  SELECT * INTO c FROM omg_private.work_confirmations WHERE id=p_confirmation_id AND work_session_id=s.id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','not_found','message','현재 근무의 확인 요청이 아닙니다.');END IF;
  IF c.confirmed_at IS NOT NULL THEN accepted:=true;
  ELSIF c.ended_at IS NULL AND c.cancelled_at IS NULL AND c.deadline_at>t AND s.status='working' THEN
   UPDATE omg_private.work_confirmations SET confirmed_at=t WHERE id=c.id;
   UPDATE public.work_sessions SET next_confirmation_at=c.due_at+interval '12 hours' WHERE id=s.id;
   UPDATE public.property_message_recipients SET read_at=coalesce(read_at,t) WHERE message_id=c.id AND employee_id=s.employee_id;
   accepted:=true;
  END IF;
 END IF;
 SELECT * INTO c FROM omg_private.work_confirmations WHERE work_session_id=s.id AND confirmed_at IS NULL
  AND ended_at IS NULL AND cancelled_at IS NULL ORDER BY due_at LIMIT 1;
 RETURN jsonb_build_object('ok',true,'confirmed',accepted,'server_now',clock_timestamp(),'session',omg_private.session_result(s.id),
  'pending',CASE WHEN c.id IS NULL THEN NULL ELSE jsonb_build_object('id',c.id,'deadline_at',c.deadline_at,'requested_at',c.requested_at) END);
END $$;
REVOKE ALL ON FUNCTION public.work_shift_confirmation(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.work_shift_confirmation(uuid,uuid) TO anon,authenticated;

CREATE FUNCTION public.begin_next_work_shift(p_access_token uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.work_sessions%rowtype;n public.work_sessions%rowtype;employee uuid;t timestamptz;tz text;
BEGIN
 SELECT w.employee_id INTO employee FROM public.work_sessions w JOIN public.employees e ON e.id=w.employee_id
  WHERE w.login_token_hash=omg_private.token_hash(p_access_token) AND w.token_expires_at>clock_timestamp() AND e.active;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','invalid_session');END IF;
 PERFORM 1 FROM public.employees WHERE id=employee FOR UPDATE;
 SELECT * INTO s FROM public.work_sessions WHERE login_token_hash=omg_private.token_hash(p_access_token)
  AND token_expires_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','invalid_session');END IF;
 IF s.status='working' THEN RETURN omg_private.session_result(s.id);END IF;
 IF s.unconfirmed_ended_at IS NULL THEN RETURN jsonb_build_object('ok',false,'message','다시 로그인하여 새 근무를 시작해주세요.');END IF;
 IF EXISTS(SELECT 1 FROM public.work_sessions WHERE employee_id=employee AND status='working') THEN
  RETURN jsonb_build_object('ok',false,'message','이미 시작된 근무가 있습니다. 화면을 새로고침해주세요.');END IF;
 t:=clock_timestamp();SELECT timezone INTO tz FROM public.properties WHERE id=s.property_id;
 -- Transfer the same device token; the historical missing-checkout row stays intact.
 UPDATE public.work_sessions SET login_token_hash=omg_private.token_hash(gen_random_uuid()),token_expires_at='-infinity'::timestamptz WHERE id=s.id;
 INSERT INTO public.work_sessions(business_id,property_id,employee_id,shift,work_date,clock_in_at,login_token_hash,token_expires_at)
  VALUES(s.business_id,s.property_id,s.employee_id,'general',(t AT TIME ZONE tz)::date,t,omg_private.token_hash(p_access_token),'infinity'::timestamptz) RETURNING * INTO n;
 UPDATE public.native_push_devices SET expires_at=n.token_expires_at WHERE session_hash=n.login_token_hash;
 RETURN omg_private.session_result(n.id);
END $$;
REVOKE ALL ON FUNCTION public.begin_next_work_shift(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.begin_next_work_shift(uuid) TO anon,authenticated;

CREATE OR REPLACE FUNCTION omg_private.session_result(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'ok', true, 'session_id', s.id, 'employee_id', e.id,
    'employee_name', e.display_name, 'role', e.role, 'session_kind', 'staff',
    'business_id', s.business_id, 'property_id', s.property_id,
    'property_name', p.name, 'report_config', e.report_config,
    'timezone', p.timezone, 'shift', s.shift, 'work_date', s.work_date,
    'clock_in_at', s.clock_in_at, 'clock_out_at', s.clock_out_at,
    'expires_at', case when s.token_expires_at='infinity'::timestamptz then to_jsonb('9999-12-31T23:59:59Z'::text) else to_jsonb(s.token_expires_at) end, 'status', s.status,
    'checkin_report_at', s.checkin_report_at,
    'checkout_report_at', s.checkout_report_at, 'unconfirmed_ended_at',s.unconfirmed_ended_at, 'next_confirmation_at',s.next_confirmation_at
  )
  from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  join public.properties p on p.id = s.property_id
  where s.id = p_session_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_work_session(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid;
begin
  select s.id into v_id from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  perform omg_private.process_work_confirmation(v_id,clock_timestamp());
  return omg_private.session_result(v_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_work_session(p_employee_id uuid, p_pin text, p_shift text DEFAULT 'general'::text, p_business_code text DEFAULT 'omg'::text, p_property_code text DEFAULT 'seoul-station'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    if (v_session.work_date < v_date and v_session.checkin_report_at is null and v_session.nfc_entry_at is null)
       or (v_session.checkin_report_at is null and coalesce(v_session.first_login_at,v_session.clock_in_at) < v_now - interval '20 hours') then
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
      token_expires_at = case when checkin_report_at is not null then 'infinity'::timestamptz else least(v_now + interval '20 hours', coalesce(first_login_at,clock_in_at) + interval '20 hours') end,
      next_confirmation_at=case when checkin_report_at is not null then coalesce(next_confirmation_at,greatest(checkin_report_at+interval '12 hours',v_now)) else null end
    where id = v_session.id returning * into v_session;
  end if;
  v_warnings:=public.evaluate_attendance_warnings(v_token,'login');
  return omg_private.session_result(v_session.id)
    || jsonb_build_object('access_token', v_token, 'resumed', v_resumed,'warning_message_ids',coalesce(v_warnings->'message_ids','[]'::jsonb));
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

CREATE OR REPLACE FUNCTION public.attendance_nfc_entry(p_access_token uuid, p_tag_uid text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  'already_recorded',v_seen,'checkin_report_at',v_session.checkin_report_at,'status',v_session.status,'clock_in_at',v_session.clock_in_at,'clock_out_at',v_session.clock_out_at,'unconfirmed_ended_at',v_session.unconfirmed_ended_at);
end $function$;

CREATE OR REPLACE FUNCTION public.get_chat_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;v_bot_mode text;v_bot_name text;v_is_bot boolean;
begin
 if exists(select 1 from public.property_messages where id=p_message_id and source='work_confirmation') then
  if not exists(select 1 from omg_private.work_confirmations c join public.work_sessions w on w.id=c.work_session_id
   where c.id=p_message_id and c.confirmed_at is null and c.ended_at is null and c.cancelled_at is null and c.deadline_at>clock_timestamp() and w.status='working') then
   return jsonb_build_object('ok',true,'recipient_topics','[]'::jsonb,'recipient_modes','{}'::jsonb,'message_id',p_message_id,'message','근무 확인 종료');
  end if;
  select jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'message_type','work_confirmation',
   'sender_label','근무 12시간 초과 알림','priority','normal','recipient_topics',jsonb_build_array('property_'||p.management_number||'_employee_'||r.employee_id),
   'recipient_modes',jsonb_build_object('property_'||p.management_number||'_employee_'||r.employee_id,'normal')) into v_payload
  from public.property_messages m join public.property_message_recipients r on r.message_id=m.id
   join public.properties p on p.id=m.property_id where m.id=p_message_id;
  return v_payload;
 end if;
 v_payload:=omg_private.chat_push_payload(p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]',coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림')
 into v_is_bot,v_bot_mode,v_bot_name from public.property_messages m left join public.notification_bots b on b.property_id=m.property_id where m.id=p_message_id;
 if not coalesce(v_is_bot,false) then v_bot_mode:=null;end if;

 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and e.active
  and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions ws where ws.employee_id=e.id and ws.status='working' and ws.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then coalesce(active.alert_mode,'urgent') else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
  from recipients r left join public.guest_chat_alert_preferences n on n.actor_key=r.actor_key
  left join lateral(
   select s->>'alert_mode' alert_mode from jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone (select timezone from public.properties where id=n.home_property_id)t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.target_property=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   order by case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end desc limit 1
  )active on true
  where n.actor_key is null or active.alert_mode is not null
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from targets;
 if v_is_bot then v_payload:=v_payload||jsonb_build_object('sender_label',v_bot_name,'is_bot',true,'priority',case when v_bot_mode='urgent' then 'urgent' else 'normal' end);end if;
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$function$;

CREATE OR REPLACE FUNCTION public.list_property_messages(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property_id uuid;
  v_owner_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb:='[]'::jsonb;v_recipients jsonb:='[]'::jsonb;v_unread integer:=0;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;v_property_id:=v_owner_session.property_id;v_owner_id:=v_owner_session.owner_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    v_property_id:=v_work_session.property_id;v_employee_id:=v_work_session.employee_id;
  end if;
  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients from(
    select jsonb_build_object('recipient_key','owner:'||o.id,'recipient_type','owner','owner_id',o.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
      'sort_key','1'||p.name||e.created_at::text)x from public.employees e join public.properties p on p.id=e.property_id
    where e.active and e.role<>'owner' and e.id<>coalesce(v_employee_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and(e.property_id=v_property_id or exists(select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id))))
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,r.acknowledged_at current_acknowledged_at,r.acknowledged_name current_acknowledged_name,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null)
      and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',case when m.source='work_confirmation' then 'work_confirmation' else m.message_type end,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.source='reminder' then case when m.message like 'To do 알림%' then 'To do 알림' else '일정 알림' end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at,'acknowledged_name',rr.acknowledged_name,'acknowledged_understood',rr.acknowledged_understood,'read_at',rr.read_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'holiday_request_id',m.holiday_request_id,'approval_status',coalesce(ar.status,psr.status,hr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date,'attendance_timezone',(select ap.timezone from public.properties ap where ap.id=ws.property_id)) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.holiday_requests hr on hr.id=m.holiday_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$function$;


CREATE OR REPLACE FUNCTION public.request_missing_checkout_adjustment(p_access_token uuid, p_work_session_id uuid, p_clock_in_time time without time zone, p_clock_out_time time without time zone, p_clock_out_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_login public.work_sessions%rowtype;v_target public.work_sessions%rowtype;v_employee_name text;v_timezone text;
  v_requested_clock_in_at timestamptz;v_requested_clock_out_at timestamptz;v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_login from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 수정 요청할 수 있습니다.'); end if;
  select s.* into v_target from public.work_sessions s where s.id=p_work_session_id and s.property_id=v_login.property_id and s.employee_id=v_login.employee_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 근무 기록을 찾을 수 없습니다.'); end if;
  if v_target.unconfirmed_ended_at is null or v_target.clock_out_at is not null or v_target.status<>'completed' then return jsonb_build_object('ok',false,'message','자동 종료된 미기록 근무만 수정할 수 있습니다.');end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_target.property_id;
  if p_clock_in_time is null or p_clock_out_time is null or p_clock_out_date is null then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  v_requested_clock_in_at:=(v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_requested_clock_out_at:=(p_clock_out_date+p_clock_out_time) at time zone v_timezone;
  if v_requested_clock_out_at<=v_requested_clock_in_at then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  if v_requested_clock_in_at>clock_timestamp() or v_requested_clock_out_at>clock_timestamp() then return jsonb_build_object('ok',false,'code','future_time','message','현재 시각 이후의 출근·퇴근시간은 입력할 수 없습니다.'); end if;
  if exists(select 1 from public.attendance_adjustment_requests r where r.work_session_id=v_target.id and r.status<>'rejected') then return jsonb_build_object('ok',false,'code','already_requested','message','이미 제출된 수정 요청이 있습니다.'); end if;
  insert into public.attendance_adjustment_requests(business_id,property_id,employee_id,work_session_id,original_clock_in_at,original_clock_out_at,requested_clock_in_at,requested_clock_out_at)
  values(v_target.business_id,v_target.property_id,v_target.employee_id,v_target.id,v_target.clock_in_at,v_target.clock_out_at,v_requested_clock_in_at,v_requested_clock_out_at) returning id into v_request_id;
  select e.display_name into v_employee_name from public.employees e where e.id=v_target.employee_id;
  v_message:=format(E'출퇴근 시간 수정 요청\n근무일: %s\n기존: %s ~ %s\n요청: %s ~ %s',v_target.work_date,
    to_char(v_target.clock_in_at at time zone v_timezone,'YYYY-MM-DD HH24:MI'),coalesce(to_char(v_target.clock_out_at at time zone v_timezone,'YYYY-MM-DD HH24:MI'),'-'),
    to_char(v_requested_clock_in_at at time zone v_timezone,'YYYY-MM-DD HH24:MI'),to_char(v_requested_clock_out_at at time zone v_timezone,'YYYY-MM-DD HH24:MI'));
  insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type,attendance_request_id)
  values(v_target.business_id,v_target.property_id,'staff',v_target.employee_id,v_message,'normal','attendance_approval',v_request_id) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select distinct v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.active and(o.property_id=v_target.property_id or exists(
    select 1 from public.property_share_requests r where r.target_property_id=v_target.property_id and r.requester_property_id=o.property_id
      and r.status='approved' and 'messages'=any(r.requested_permissions)));
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending','employee_name',v_employee_name);
end;
$function$;
REVOKE ALL ON FUNCTION public.request_missing_checkout_adjustment(uuid,uuid,time,time,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_missing_checkout_adjustment(uuid,uuid,time,time,date) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.list_employee_payroll(p_access_token uuid, p_month date, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_own uuid; v_ids uuid[]; v_month date; v_items jsonb;
begin
  select s.property_id into v_own from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.'); end if;
  if p_month is null or p_month<'2000-01-01'::date or p_month>'2100-12-31'::date then
    return jsonb_build_object('ok',false,'message','조회할 급여월을 확인해주세요.'); end if;
  v_month:=date_trunc('month',p_month)::date;
  v_ids:=case when p_property_ids is null then array[v_own] else p_property_ids end;
  if exists(select 1 from unnest(v_ids) x(id) where not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'attendance'),false)
    or not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'account_settings'),false)) then
    return jsonb_build_object('ok',false,'message','급여정보는 근태 및 계정관리 권한이 모두 있는 지점에서 조회할 수 있습니다. 지점 선택을 확인해주세요.');
  end if;
  with settings as (
    select e.id employee_id,e.display_name,e.active,e.created_at,p.id property_id,p.name property_name,p.timezone,
      coalesce(c.pay_type,'hourly') pay_type,c.hourly_rate,c.monthly_salary,coalesce(c.cycle_start_day,1) cycle_start_day,
      c.pay_day,coalesce(c.pay_month_offset,1) pay_month_offset
    from public.employees e join public.properties p on p.id=e.property_id
    left join public.employee_payroll_settings c on c.employee_id=e.id
    where e.property_id=any(v_ids) and e.role<>'owner'
  ), periods as (
    select x.*,v_month+(x.cycle_start_day-1) period_start,
      (v_month+interval '1 month')::date+(x.cycle_start_day-2) period_end from settings x
  ), totals as (
    select x.*,w.work_minutes,w.break_minutes,w.work_days,w.missing_count,w.working_count,w.session_count,
      (date_trunc('month',x.period_end)+make_interval(months=>x.pay_month_offset))::date pay_month
    from periods x cross join lateral (
      select coalesce(sum(case when s.clock_out_at is not null then greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)) else 0 end),0)::bigint work_minutes,
        coalesce(sum(case when s.clock_out_at is not null then case when floor(extract(epoch from (s.clock_out_at-s.clock_in_at))/60)>=540 then 60 when floor(extract(epoch from (s.clock_out_at-s.clock_in_at))/60)>=270 then 30 else 0 end else 0 end),0)::bigint break_minutes,
        count(distinct s.work_date) filter(where s.clock_out_at is not null)::integer work_days,
        count(*) filter(where s.clock_out_at is null and (s.status in('needs_review','completed') or s.work_date<(clock_timestamp() at time zone x.timezone)::date))::integer missing_count,
        count(*) filter(where s.clock_out_at is null and s.status='working' and s.work_date>=(clock_timestamp() at time zone x.timezone)::date)::integer working_count,
        count(*) session_count
      from public.work_sessions s where s.employee_id=x.employee_id and s.property_id=x.property_id and s.work_date between x.period_start and x.period_end
    ) w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',x.employee_id,'display_name',x.display_name,'active',x.active,'property_id',x.property_id,'property_name',x.property_name,
    'pay_type',x.pay_type,'hourly_rate',x.hourly_rate,'monthly_salary',x.monthly_salary,'cycle_start_day',x.cycle_start_day,
    'pay_day',x.pay_day,'pay_month_offset',x.pay_month_offset,'period_start',x.period_start,'period_end',x.period_end,
    'pay_date',case when x.pay_day is null then null else x.pay_month+least(x.pay_day,extract(day from x.pay_month+interval '1 month - 1 day')::integer)-1 end,
    'work_minutes',x.work_minutes,'break_minutes',x.break_minutes,'work_days',x.work_days,'missing_count',x.missing_count,'working_count',x.working_count,
    'expected_pay',case when x.pay_type='monthly' then x.monthly_salary::numeric else round(x.hourly_rate::numeric*x.work_minutes/60) end
  ) order by x.property_name,x.created_at,x.employee_id),'[]'::jsonb) into v_items
  from totals x where x.active or x.session_count>0;
  return jsonb_build_object('ok',true,'employees',v_items,'month',v_month);
end $function$;

CREATE OR REPLACE FUNCTION public.list_employee_payroll_range(p_access_token uuid, p_from_date date, p_to_date date, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_own uuid; v_ids uuid[]; v_month date; v_items jsonb;
begin
  select s.property_id into v_own from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.'); end if;
  if p_from_date is null or p_to_date is null or p_from_date<'2000-01-01'::date or p_to_date>'2100-12-31'::date or p_to_date<p_from_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'message','조회기간은 시작일 이후 최대 366일로 선택해주세요.'); end if;
  v_month:=date_trunc('month',p_from_date)::date;
  v_ids:=case when p_property_ids is null then array[v_own] else p_property_ids end;
  if exists(select 1 from unnest(v_ids) x(id) where not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'attendance'),false)
    or not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'account_settings'),false)) then
    return jsonb_build_object('ok',false,'message','급여정보는 근태 및 계정관리 권한이 모두 있는 지점에서 조회할 수 있습니다. 지점 선택을 확인해주세요.');
  end if;
  with settings as (
    select e.id employee_id,e.display_name,e.active,e.created_at,p.id property_id,p.name property_name,p.timezone,
      coalesce(c.pay_type,'hourly') pay_type,c.hourly_rate,c.monthly_salary,coalesce(c.cycle_start_day,1) cycle_start_day,
      c.pay_day,coalesce(c.pay_month_offset,1) pay_month_offset
    from public.employees e join public.properties p on p.id=e.property_id
    left join public.employee_payroll_settings c on c.employee_id=e.id
    where e.property_id=any(v_ids) and e.role<>'owner'
  ), periods as (
    select x.*,p_from_date period_start,p_to_date period_end from settings x
  ), totals as (
    select x.*,w.work_minutes,w.break_minutes,w.work_days,w.missing_count,w.working_count,w.session_count,
      (date_trunc('month',x.period_end)+make_interval(months=>x.pay_month_offset))::date pay_month
    from periods x cross join lateral (
      select coalesce(sum(case when s.clock_out_at is not null then greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)) else 0 end),0)::bigint work_minutes,
        coalesce(sum(case when s.clock_out_at is not null then case when floor(extract(epoch from (s.clock_out_at-s.clock_in_at))/60)>=540 then 60 when floor(extract(epoch from (s.clock_out_at-s.clock_in_at))/60)>=270 then 30 else 0 end else 0 end),0)::bigint break_minutes,
        count(distinct s.work_date) filter(where s.clock_out_at is not null)::integer work_days,
        count(*) filter(where s.clock_out_at is null and (s.status in('needs_review','completed') or s.work_date<(clock_timestamp() at time zone x.timezone)::date))::integer missing_count,
        count(*) filter(where s.clock_out_at is null and s.status='working' and s.work_date>=(clock_timestamp() at time zone x.timezone)::date)::integer working_count,
        count(*) session_count
      from public.work_sessions s where s.employee_id=x.employee_id and s.property_id=x.property_id and s.work_date between x.period_start and x.period_end
    ) w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',x.employee_id,'display_name',x.display_name,'active',x.active,'property_id',x.property_id,'property_name',x.property_name,
    'pay_type',x.pay_type,'hourly_rate',x.hourly_rate,'monthly_salary',x.monthly_salary,'cycle_start_day',x.cycle_start_day,
    'pay_day',x.pay_day,'pay_month_offset',x.pay_month_offset,'period_start',x.period_start,'period_end',x.period_end,
    'pay_date',case when x.pay_day is null then null else x.pay_month+least(x.pay_day,extract(day from x.pay_month+interval '1 month - 1 day')::integer)-1 end,
    'work_minutes',x.work_minutes,'break_minutes',x.break_minutes,'work_days',x.work_days,'missing_count',x.missing_count,'working_count',x.working_count,
    'expected_pay',case when x.pay_type='monthly' then case when extract(day from p_from_date)=x.cycle_start_day and extract(day from p_to_date+1)=x.cycle_start_day then x.monthly_salary::numeric*(12*(extract(year from p_to_date+1)-extract(year from p_from_date))+extract(month from p_to_date+1)-extract(month from p_from_date)) else null end else round(x.hourly_rate::numeric*x.work_minutes/60) end
  ) order by x.property_name,x.created_at,x.employee_id),'[]'::jsonb) into v_items
  from totals x where x.active or x.session_count>0;
  return jsonb_build_object('ok',true,'employees',v_items,'from_date',p_from_date,'to_date',p_to_date);
end $function$;


-- Only currently valid logins are extended. Do not revive expired/revoked tokens.
UPDATE public.work_sessions SET token_expires_at='infinity'::timestamptz,
 next_confirmation_at=greatest(checkin_report_at+interval '12 hours',clock_timestamp())
 WHERE status='working' AND checkin_report_at IS NOT NULL AND clock_out_at IS NULL AND token_expires_at>clock_timestamp();
SELECT cron.schedule('oms-work-confirmation','* * * * *','select omg_private.process_work_confirmations();');
