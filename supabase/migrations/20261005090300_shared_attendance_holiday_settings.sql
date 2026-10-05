CREATE OR REPLACE FUNCTION public.shared_property_attendance_clock_in_basis(p_access_token uuid,p_property_id uuid, p_action text, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid; v_basis text;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 만료되었습니다.'); end if;
  if not omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') then return jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); end if;
  v_property_id:=p_property_id;
  if p_action='save' then
    if p_basis is null or p_basis not in ('first_login','report') then
      return jsonb_build_object('ok',false,'message','출근시간 기준을 선택해주세요.');
    end if;
    update public.properties set clock_in_basis=p_basis where id=v_property_id;
  elsif p_action is distinct from 'get' then
    return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');
  end if;
  select p.clock_in_basis into v_basis from public.properties p where p.id=v_property_id;
  return jsonb_build_object('ok',true,'basis',v_basis);
end;
$function$
;
REVOKE ALL ON FUNCTION public.shared_property_attendance_clock_in_basis(uuid,uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_property_attendance_clock_in_basis(uuid,uuid,text,text) TO anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.shared_holiday_request_settings(p_access_token uuid,p_property_id uuid,p_action text,p_data jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_settings public.holiday_request_settings%rowtype;
BEGIN
 IF NOT omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings') THEN RETURN jsonb_build_object('ok',false,'message','숙소 설정 권한이 없습니다.'); END IF;
 IF p_action NOT IN ('settings_get','settings_save') THEN RETURN jsonb_build_object('ok',false,'message','잘못된 요청입니다.'); END IF;
 SELECT * INTO v_settings FROM public.holiday_request_settings WHERE property_id=p_property_id;
 IF NOT FOUND THEN
   v_settings.property_id:=p_property_id;v_settings.notice_enabled:=true;v_settings.notice_text:='휴일 신청은 관리자 결재 후 확정됩니다.';
   v_settings.acknowledgement_required:=true;v_settings.acknowledgement_label:='이해했음';
 END IF;
 IF p_action='settings_save' THEN
   v_settings.notice_enabled:=coalesce((p_data->>'notice_enabled')::boolean,false);
   v_settings.notice_text:=btrim(coalesce(p_data->>'notice_text',''));
   v_settings.acknowledgement_required:=coalesce((p_data->>'acknowledgement_required')::boolean,true);
   v_settings.acknowledgement_label:=btrim(coalesce(p_data->>'acknowledgement_label','이해했음'));
   IF char_length(v_settings.notice_text)>4000 OR (v_settings.notice_enabled AND v_settings.notice_text='')
      OR char_length(v_settings.acknowledgement_label) NOT BETWEEN 1 AND 100 THEN
     RETURN jsonb_build_object('ok',false,'message','공지 내용과 이해 확인 문구를 확인해주세요.');
   END IF;
   INSERT INTO public.holiday_request_settings(property_id,notice_enabled,notice_text,acknowledgement_required,acknowledgement_label)
   VALUES(p_property_id,v_settings.notice_enabled,v_settings.notice_text,v_settings.acknowledgement_required,v_settings.acknowledgement_label)
   ON CONFLICT(property_id) DO UPDATE SET notice_enabled=excluded.notice_enabled,notice_text=excluded.notice_text,
     acknowledgement_required=excluded.acknowledgement_required,acknowledgement_label=excluded.acknowledgement_label,updated_at=clock_timestamp()
   RETURNING * INTO v_settings;
 END IF;
 RETURN jsonb_build_object('ok',true,'settings',to_jsonb(v_settings));
END $$;
REVOKE ALL ON FUNCTION public.shared_holiday_request_settings(uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shared_holiday_request_settings(uuid,uuid,text,jsonb) TO anon,authenticated,service_role;
