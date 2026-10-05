CREATE OR REPLACE FUNCTION public.get_reminder_push_dispatch(p_message_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_message record;v_topics jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT m.*,p.management_number INTO v_message FROM public.property_messages m JOIN public.properties p ON p.id=m.property_id
 WHERE m.id=p_message_id AND m.source='reminder';
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT coalesce(jsonb_agg('property_'||v_message.management_number||'_'||
     CASE WHEN r.recipient_type='staff' THEN 'employee_'||r.employee_id ELSE 'owner_'||r.owner_id END),'[]'::jsonb)
 INTO v_topics FROM public.property_message_recipients r WHERE r.message_id=p_message_id;
 RETURN jsonb_build_object('ok',true,'message_id',p_message_id,'message',v_message.message,'recipient_topics',v_topics);
END $$;
