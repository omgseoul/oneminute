CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_setting record;v_item record;v_message_id uuid;v_count integer:=0;v_offset integer;v_recipient_count integer;v_secret text;v_url text;
BEGIN
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 FOR v_setting IN
  SELECT s.*,p.business_id,p.management_number,p.timezone,
   (clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'))::date AS local_today
  FROM public.property_reminder_settings s JOIN public.properties p ON p.id=s.property_id
  WHERE s.send_when<>'off' AND (s.notify_staff OR s.notify_owner)
    AND to_char(clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'),'HH24:MI')=to_char(s.send_time,'HH24:MI')
 LOOP
  FOR v_item IN
    SELECT 'todo'::text AS kind,m.id,m.title,m.due_at AS due_at,m.target_employee_ids AS targets, true AS owner_target
      FROM public.missions m WHERE v_setting.kind='todo' AND m.property_id=v_setting.property_id AND m.active AND m.due_at IS NOT NULL
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids),c.owner_target
      FROM public.calendar_events c WHERE v_setting.kind='calendar' AND c.property_id=v_setting.property_id AND c.holiday_request_id IS NULL
  LOOP
   FOR v_offset IN SELECT offset_day FROM (VALUES(0),(1)) offsets(offset_day)
     WHERE (offset_day=0 AND v_setting.send_when IN ('today','both'))
        OR (offset_day=1 AND v_setting.send_when IN ('before','both')) LOOP
     IF (v_item.due_at AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'))::date<>v_setting.local_today+v_offset THEN CONTINUE; END IF;
     INSERT INTO public.reminder_deliveries(kind,item_id,offset_days) VALUES(v_item.kind,v_item.id,v_offset)
     ON CONFLICT DO NOTHING;
     IF NOT FOUND THEN CONTINUE; END IF;
     INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
     VALUES(v_setting.business_id,v_setting.property_id,'system',
       (CASE WHEN v_item.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END)||E'\n'||(CASE WHEN v_offset=1 THEN '내일: ' ELSE '오늘: ' END)||left(v_item.title,120),
       'normal','general','reminder') RETURNING id INTO v_message_id;
     IF v_setting.notify_staff THEN
       INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
       SELECT v_message_id,'employee:'||e.id,'staff',e.id FROM public.employees e
       WHERE e.property_id=v_setting.property_id AND e.active AND e.role<>'owner'
        AND (v_item.kind='todo' AND (jsonb_array_length(coalesce(v_item.targets,'[]'::jsonb))=0 OR to_jsonb(e.id)<@v_item.targets)
          OR v_item.kind='calendar' AND to_jsonb(e.id)<@v_item.targets)
       ON CONFLICT DO NOTHING;
     END IF;
     IF v_setting.notify_owner THEN
       INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
       SELECT v_message_id,'owner:'||o.id,'owner',o.id FROM public.owners o WHERE o.property_id=v_setting.property_id AND o.active
       ON CONFLICT DO NOTHING;
     END IF;
     SELECT count(*) INTO v_recipient_count FROM public.property_message_recipients WHERE message_id=v_message_id;
     IF v_recipient_count=0 THEN
       DELETE FROM public.reminder_deliveries WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND message_id IS NULL;
       DELETE FROM public.property_messages WHERE id=v_message_id;
       CONTINUE;
     END IF;
     UPDATE public.reminder_deliveries SET message_id=v_message_id WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset;
     v_url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder';
     PERFORM net.http_post(url:=v_url,headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message_id));
     v_count:=v_count+1;
   END LOOP;
  END LOOP;
 END LOOP;
 RETURN v_count;
END $$;
