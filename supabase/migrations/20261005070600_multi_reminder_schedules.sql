ALTER TABLE public.property_reminder_settings
  ADD COLUMN schedules jsonb NOT NULL DEFAULT '[{"offset_days":1,"send_time":"09:00"}]'::jsonb;

UPDATE public.property_reminder_settings
SET schedules=CASE send_when
  WHEN 'off' THEN '[]'::jsonb
  WHEN 'today' THEN jsonb_build_array(jsonb_build_object('offset_days',0,'send_time',to_char(send_time,'HH24:MI')))
  WHEN 'both' THEN jsonb_build_array(jsonb_build_object('offset_days',1,'send_time',to_char(send_time,'HH24:MI')),jsonb_build_object('offset_days',0,'send_time',to_char(send_time,'HH24:MI')))
  ELSE jsonb_build_array(jsonb_build_object('offset_days',1,'send_time',to_char(send_time,'HH24:MI')))
END;

ALTER TABLE public.property_reminder_settings
  ADD CONSTRAINT property_reminder_schedules_valid CHECK(jsonb_typeof(schedules)='array' AND jsonb_array_length(schedules)<=10);

ALTER TABLE public.reminder_deliveries ADD COLUMN send_time time NOT NULL DEFAULT '00:00';
ALTER TABLE public.reminder_deliveries DROP CONSTRAINT reminder_deliveries_pkey;
ALTER TABLE public.reminder_deliveries ADD PRIMARY KEY(kind,item_id,offset_days,send_time);

CREATE OR REPLACE FUNCTION public.get_property_reminder_settings(p_access_token uuid,p_property_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_settings jsonb;
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('kind',k.kind,'schedules',coalesce(s.schedules,'[{"offset_days":1,"send_time":"09:00"}]'::jsonb),'notify_staff',coalesce(s.notify_staff,true),'notify_owner',coalesce(s.notify_owner,true)) ORDER BY k.kind),'[]'::jsonb) INTO v_settings
 FROM (VALUES('todo'),('calendar')) k(kind) LEFT JOIN public.property_reminder_settings s ON s.property_id=p_property_id AND s.kind=k.kind;
 RETURN jsonb_build_object('ok',true,'settings',v_settings);
END $$;

CREATE OR REPLACE FUNCTION public.save_property_reminder_settings(p_access_token uuid,p_property_id uuid,p_settings jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_item jsonb;v_schedule jsonb;v_schedules jsonb;v_normalized jsonb;v_offset integer;v_time time;v_first_time time;
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 IF jsonb_typeof(p_settings)<>'array' OR jsonb_array_length(p_settings)<>2 THEN RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.'); END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_settings) LOOP
   v_schedules:=v_item->'schedules';v_normalized:='[]'::jsonb;v_first_time:='09:00'::time;
   IF v_item->>'kind' NOT IN ('todo','calendar') OR jsonb_typeof(v_schedules)<>'array' OR jsonb_array_length(v_schedules)>10
      OR jsonb_typeof(v_item->'notify_staff')<>'boolean' OR jsonb_typeof(v_item->'notify_owner')<>'boolean' THEN
      RETURN jsonb_build_object('ok',false,'message','알림 설정을 확인해주세요.');
   END IF;
   FOR v_schedule IN SELECT value FROM jsonb_array_elements(v_schedules) LOOP
     IF jsonb_typeof(v_schedule)<>'object' OR coalesce(v_schedule->>'offset_days','') !~ '^[0-9]{1,3}$' OR coalesce(v_schedule->>'send_time','') !~ '^[0-2][0-9]:[0-5][0-9]$' THEN
       RETURN jsonb_build_object('ok',false,'message','발송 날짜와 시각을 확인해주세요.');
     END IF;
     v_offset:=(v_schedule->>'offset_days')::integer;v_time:=(v_schedule->>'send_time')::time;
     IF v_offset<0 OR v_offset>365 OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_normalized) x(value) WHERE (x.value->>'offset_days')::integer=v_offset AND (x.value->>'send_time')::time=v_time) THEN
       RETURN jsonb_build_object('ok',false,'message','알림 조건은 서로 다른 날짜 또는 시각으로 설정해주세요.');
     END IF;
     IF jsonb_array_length(v_normalized)=0 THEN v_first_time:=v_time; END IF;
     v_normalized:=v_normalized||jsonb_build_array(jsonb_build_object('offset_days',v_offset,'send_time',to_char(v_time,'HH24:MI')));
   END LOOP;
   INSERT INTO public.property_reminder_settings(property_id,kind,send_when,send_time,notify_staff,notify_owner,schedules)
   VALUES(p_property_id,v_item->>'kind',CASE WHEN jsonb_array_length(v_normalized)=0 THEN 'off' ELSE 'before' END,v_first_time,(v_item->>'notify_staff')::boolean,(v_item->>'notify_owner')::boolean,v_normalized)
   ON CONFLICT(property_id,kind) DO UPDATE SET send_when=excluded.send_when,send_time=excluded.send_time,notify_staff=excluded.notify_staff,notify_owner=excluded.notify_owner,schedules=excluded.schedules;
 END LOOP;
 RETURN public.get_property_reminder_settings(p_access_token,p_property_id);
EXCEPTION WHEN invalid_datetime_format OR numeric_value_out_of_range THEN RETURN jsonb_build_object('ok',false,'message','발송 날짜와 시각을 확인해주세요.');
END $$;

REVOKE ALL ON FUNCTION public.get_property_reminder_settings(uuid,uuid),public.save_property_reminder_settings(uuid,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_property_reminder_settings(uuid,uuid),public.save_property_reminder_settings(uuid,uuid,jsonb) TO anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_setting record;v_schedule record;v_item record;v_message_id uuid;v_count integer:=0;v_offset integer;v_send_time time;v_recipient_count integer;v_secret text;v_url text;
BEGIN
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 FOR v_setting IN
  SELECT s.*,p.business_id,p.management_number,p.timezone,(clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'))::date AS local_today
  FROM public.property_reminder_settings s JOIN public.properties p ON p.id=s.property_id
  WHERE jsonb_array_length(s.schedules)>0 AND (s.notify_staff OR s.notify_owner)
 LOOP
  FOR v_schedule IN SELECT (x.value->>'offset_days')::integer offset_days,(x.value->>'send_time')::time send_time FROM jsonb_array_elements(v_setting.schedules) x(value)
    WHERE to_char(clock_timestamp() AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'),'HH24:MI')=x.value->>'send_time'
  LOOP
   v_offset:=v_schedule.offset_days;v_send_time:=v_schedule.send_time;
   FOR v_item IN
    SELECT 'todo'::text AS kind,m.id,m.title,m.due_at AS due_at,m.target_employee_ids AS targets,true AS owner_target
      FROM public.missions m WHERE v_setting.kind='todo' AND m.property_id=v_setting.property_id AND m.active AND m.due_at IS NOT NULL
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids),c.owner_target
      FROM public.calendar_events c WHERE v_setting.kind='calendar' AND c.property_id=v_setting.property_id AND c.holiday_request_id IS NULL
   LOOP
    IF (v_item.due_at AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'))::date<>v_setting.local_today+v_offset THEN CONTINUE; END IF;
    INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time) VALUES(v_item.kind,v_item.id,v_offset,v_send_time) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN CONTINUE; END IF;
    INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
    VALUES(v_setting.business_id,v_setting.property_id,'system',(CASE WHEN v_item.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END)||E'\n'||(CASE WHEN v_offset=0 THEN '오늘: ' WHEN v_offset=1 THEN '내일: ' ELSE v_offset||'일 후: ' END)||left(v_item.title,120),'normal','general','reminder') RETURNING id INTO v_message_id;
    IF v_setting.notify_staff THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
      SELECT v_message_id,'employee:'||e.id,'staff',e.id FROM public.employees e
      WHERE e.property_id=v_setting.property_id AND e.active AND e.role<>'owner'
       AND (v_item.kind='todo' AND (jsonb_array_length(coalesce(v_item.targets,'[]'::jsonb))=0 OR to_jsonb(e.id)<@v_item.targets) OR v_item.kind='calendar' AND to_jsonb(e.id)<@v_item.targets)
      ON CONFLICT DO NOTHING;
    END IF;
    IF v_setting.notify_owner THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
      SELECT v_message_id,'owner:'||o.id,'owner',o.id FROM public.owners o WHERE o.property_id=v_setting.property_id AND o.active ON CONFLICT DO NOTHING;
    END IF;
    SELECT count(*) INTO v_recipient_count FROM public.property_message_recipients WHERE message_id=v_message_id;
    IF v_recipient_count=0 THEN
      DELETE FROM public.reminder_deliveries WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND send_time=v_send_time AND message_id IS NULL;
      DELETE FROM public.property_messages WHERE id=v_message_id;CONTINUE;
    END IF;
    UPDATE public.reminder_deliveries SET message_id=v_message_id WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND send_time=v_send_time;
    v_url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder';
    PERFORM net.http_post(url:=v_url,headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message_id));v_count:=v_count+1;
   END LOOP;
  END LOOP;
 END LOOP;
 RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION omg_private.enqueue_due_reminders() FROM PUBLIC;
