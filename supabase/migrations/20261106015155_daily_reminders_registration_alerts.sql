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
       CASE WHEN v_overdue THEN '지연: ' WHEN v_date=s.today THEN '오늘: ' WHEN v_date=s.today+1 THEN '내일: ' ELSE (v_date-s.today)||'일 후: ' END||left(i.title,120),
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

-- Registration alerts are independent of date/time reminder preferences.
CREATE OR REPLACE FUNCTION omg_private.notify_registered_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_kind text;v_targets jsonb;v_message uuid;v_secret text;v_business uuid;
BEGIN
 IF TG_TABLE_NAME='missions' THEN
  IF NOT NEW.active OR NEW.owner_completed_at IS NOT NULL THEN RETURN NEW; END IF;
  v_kind:='todo';v_targets:=coalesce(NEW.target_employee_ids,'[]'::jsonb);
 ELSE
  IF NEW.holiday_request_id IS NOT NULL THEN RETURN NEW; END IF;
  v_kind:='calendar';v_targets:=coalesce(to_jsonb(NEW.target_employee_ids),'[]'::jsonb);
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.employees e WHERE e.property_id=NEW.property_id AND e.active AND e.role<>'owner'
  AND ((v_kind='todo' AND jsonb_array_length(v_targets)=0) OR to_jsonb(e.id)<@v_targets)) THEN RETURN NEW; END IF;
 INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time,delivery_key)
 VALUES(v_kind,NEW.id,-3,'00:00','created') ON CONFLICT DO NOTHING;
 IF NOT FOUND THEN RETURN NEW; END IF;
 SELECT business_id INTO v_business FROM public.properties WHERE id=NEW.property_id;
 INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
 VALUES(v_business,NEW.property_id,'system',(CASE WHEN v_kind='todo' THEN 'To do 알림' ELSE '일정 알림' END)||E'\n등록: '||left(NEW.title,120),'normal','general','reminder') RETURNING id INTO v_message;
 INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
 SELECT v_message,'employee:'||e.id,'staff',e.id FROM public.employees e WHERE e.property_id=NEW.property_id AND e.active AND e.role<>'owner'
 AND ((v_kind='todo' AND jsonb_array_length(v_targets)=0) OR to_jsonb(e.id)<@v_targets) ON CONFLICT DO NOTHING;
 UPDATE public.reminder_deliveries SET message_id=v_message WHERE kind=v_kind AND item_id=NEW.id AND delivery_key='created';
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 PERFORM net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder',
 headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message));
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION omg_private.notify_registered_assignment() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER assignment_registration_alert AFTER INSERT ON public.missions FOR EACH ROW EXECUTE FUNCTION omg_private.notify_registered_assignment();
CREATE TRIGGER assignment_registration_alert AFTER INSERT ON public.calendar_events FOR EACH ROW EXECUTE FUNCTION omg_private.notify_registered_assignment();
