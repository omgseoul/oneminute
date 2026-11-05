-- Existing fixed-time deliveries retain the empty key and are never replayed.
ALTER TABLE public.reminder_deliveries ADD COLUMN delivery_key text NOT NULL DEFAULT '';
ALTER TABLE public.reminder_deliveries DROP CONSTRAINT reminder_deliveries_pkey;
ALTER TABLE public.reminder_deliveries ADD PRIMARY KEY(kind,item_id,offset_days,send_time,delivery_key);
CREATE INDEX IF NOT EXISTS work_sessions_reminder_checkin_idx ON public.work_sessions(property_id,checkin_report_at)
 WHERE checkin_report_at IS NOT NULL AND clock_out_at IS NULL;

CREATE OR REPLACE FUNCTION public.save_property_reminder_settings(p_access_token uuid,p_property_id uuid,p_settings jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_item jsonb;v_schedule jsonb;v_normalized jsonb;v_all jsonb:='[]';v_offset integer;v_time time;
 v_trigger text;v_repeat boolean;v_enabled timestamptz;v_existing jsonb;v_kinds text[]:='{}';
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN
  RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 IF jsonb_typeof(p_settings) IS DISTINCT FROM 'array' THEN RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.'); END IF;
 IF jsonb_array_length(p_settings)<>2 THEN RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.'); END IF;
 -- Validate both sections before writing either one.
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_settings) LOOP
  IF coalesce(v_item->>'kind','') NOT IN ('todo','calendar') OR (v_item->>'kind')=ANY(v_kinds)
   OR jsonb_typeof(v_item->'schedules') IS DISTINCT FROM 'array'
   OR jsonb_typeof(v_item->'notify_staff') IS DISTINCT FROM 'boolean'
   OR jsonb_typeof(v_item->'notify_owner') IS DISTINCT FROM 'boolean' THEN
    RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.'); END IF;
  IF jsonb_array_length(v_item->'schedules')>10 THEN RETURN jsonb_build_object('ok',false,'message','알림 조건은 최대 10개까지 설정할 수 있습니다.'); END IF;
  v_kinds:=array_append(v_kinds,v_item->>'kind');v_normalized:='[]';
  SELECT schedules INTO v_existing FROM public.property_reminder_settings WHERE property_id=p_property_id AND kind=v_item->>'kind' FOR UPDATE;
  FOR v_schedule IN SELECT value FROM jsonb_array_elements(v_item->'schedules') LOOP
   v_trigger:=coalesce(v_schedule->>'trigger','time');
   IF jsonb_typeof(v_schedule) IS DISTINCT FROM 'object'
    OR coalesce(v_schedule->>'offset_days','') !~ '^[0-9]{1,3}$'
    OR coalesce(v_schedule->>'send_time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    OR v_trigger NOT IN ('time','checkin')
    OR (v_schedule ? 'repeat_overdue' AND jsonb_typeof(v_schedule->'repeat_overdue') IS DISTINCT FROM 'boolean') THEN
     RETURN jsonb_build_object('ok',false,'message','발송 날짜와 시각을 확인해주세요.'); END IF;
   v_offset:=(v_schedule->>'offset_days')::integer;v_time:=(v_schedule->>'send_time')::time;
   v_repeat:=coalesce((v_schedule->>'repeat_overdue')::boolean,false);
   IF v_item->>'kind'='calendar' AND v_repeat THEN RETURN jsonb_build_object('ok',false,'message','일정 알림에는 지연 알림을 설정할 수 없습니다.'); END IF;
   IF v_offset>365 OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_normalized) x WHERE
    (x->>'offset_days')::int=v_offset AND x->>'trigger'=v_trigger AND (v_trigger='checkin' OR (x->>'send_time')::time=v_time)) THEN
    RETURN jsonb_build_object('ok',false,'message','알림 조건은 서로 다른 날짜 또는 시각으로 설정해주세요.'); END IF;
   -- Activation is server-owned. An old check-in cannot unlock a newly enabled rule.
   SELECT (x->>'enabled_at')::timestamptz INTO v_enabled FROM jsonb_array_elements(coalesce(v_existing,'[]')) x
    WHERE x->>'trigger'='checkin' AND (x->>'offset_days')::int=v_offset
     AND coalesce((x->>'repeat_overdue')::boolean,false)=v_repeat LIMIT 1;
   v_normalized:=v_normalized||jsonb_build_array(jsonb_build_object('offset_days',v_offset,'send_time',to_char(v_time,'HH24:MI'),
    'trigger',v_trigger,'repeat_overdue',v_repeat)||CASE WHEN v_trigger='checkin' THEN jsonb_build_object('enabled_at',coalesce(v_enabled,clock_timestamp())) ELSE '{}'::jsonb END);
  END LOOP;
  v_all:=v_all||jsonb_build_array(v_item||jsonb_build_object('schedules',v_normalized));
 END LOOP;
 FOR v_item IN SELECT value FROM jsonb_array_elements(v_all) LOOP
  INSERT INTO public.property_reminder_settings(property_id,kind,send_when,send_time,notify_staff,notify_owner,schedules)
  VALUES(p_property_id,v_item->>'kind',CASE WHEN jsonb_array_length(v_item->'schedules')=0 THEN 'off' ELSE 'before' END,
   coalesce((v_item->'schedules'->0->>'send_time')::time,'09:00'),(v_item->>'notify_staff')::boolean,(v_item->>'notify_owner')::boolean,v_item->'schedules')
  ON CONFLICT(property_id,kind) DO UPDATE SET send_when=excluded.send_when,send_time=excluded.send_time,
   notify_staff=excluded.notify_staff,notify_owner=excluded.notify_owner,schedules=excluded.schedules;
 END LOOP;
 RETURN public.get_property_reminder_settings(p_access_token,p_property_id);
END $$;

-- The timestamp argument makes date / timezone / duplicate behavior testable.
-- Only the private cron wrapper can invoke this worker from the application.
CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders_at(p_now timestamptz)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
      AND ((m.due_at AT TIME ZONE s.tz)::date=s.today+r.offset_days OR (r.repeat_overdue AND (m.due_at AT TIME ZONE s.tz)::date<s.today))
      AND NOT (m.completion_mode='any' AND EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=m.id))
      AND NOT (EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=s.property_id AND e.active AND e.role<>'owner'
        AND (jsonb_array_length(coalesce(m.target_employee_ids,'[]'))=0 OR to_jsonb(e.id)<@m.target_employee_ids))
       AND NOT EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=s.property_id AND e.active AND e.role<>'owner'
        AND (jsonb_array_length(coalesce(m.target_employee_ids,'[]'))=0 OR to_jsonb(e.id)<@m.target_employee_ids)
        AND NOT EXISTS(SELECT 1 FROM public.mission_completions c WHERE c.mission_id=m.id AND c.employee_id=e.id)))
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids) FROM public.calendar_events c
     WHERE s.kind='calendar' AND c.property_id=s.property_id AND c.holiday_request_id IS NULL
      AND (c.start_at AT TIME ZONE s.tz)::date=s.today+r.offset_days
   LOOP
    v_date:=(i.due_at AT TIME ZONE s.tz)::date;v_overdue:=i.kind='todo' AND v_date<s.today;
    -- Overdue rules with different offsets but the same time coalesce to one daily reminder.
    v_offset:=CASE WHEN v_overdue THEN -1 ELSE r.offset_days END;
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
     v_key:=CASE WHEN v_checkin THEN 'checkin:'||s.today||':'||ev.employee_id WHEN v_overdue THEN 'overdue:'||s.today ELSE '' END;
     INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time,delivery_key)
      VALUES(i.kind,i.id,v_offset,v_time,v_key) ON CONFLICT DO NOTHING;
     IF NOT FOUND THEN CONTINUE; END IF;
     INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
      VALUES(s.business_id,s.property_id,'system',CASE WHEN i.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END||E'\n'||
       CASE WHEN v_overdue THEN '지연: ' WHEN r.offset_days=0 THEN '오늘: ' WHEN r.offset_days=1 THEN '내일: ' ELSE r.offset_days||'일 후: ' END||left(i.title,120),
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
END $$;
REVOKE ALL ON FUNCTION omg_private.enqueue_due_reminders_at(timestamptz) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders()
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT omg_private.enqueue_due_reminders_at(clock_timestamp()); $$;
