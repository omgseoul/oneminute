-- Existing production function definitions used only in the disposable regression database.
CREATE OR REPLACE FUNCTION public.start_admin_session(p_owner_id uuid, p_pin text, p_business_code text DEFAULT 'omg'::text, p_property_code text DEFAULT 'seoul-station'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner public.owners%rowtype;v_session public.owner_sessions%rowtype;
  v_token uuid:=gen_random_uuid();v_now timestamptz:=clock_timestamp();v_failures integer;
begin
  if p_owner_id is null or p_pin is null or p_pin!~'^[0-9]{4,8}$' then
    return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.');end if;
  select o.* into v_owner from public.owners o join public.properties p on p.id=o.property_id and p.business_id=o.business_id
  join public.businesses b on b.id=o.business_id where o.id=p_owner_id and o.active and b.code=p_business_code and p.code=p_property_code for update of o;
  if not found then return jsonb_build_object('ok',false,'code','invalid_credentials','message','관리자와 PIN을 확인해주세요.');end if;
  if v_owner.login_locked_until>v_now then return jsonb_build_object('ok',false,'code','locked','message','PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');end if;
  v_failures:=case when v_owner.login_locked_until is not null then 0 else v_owner.login_failures end;
  if omg_private.pin_matches(p_pin,v_owner.pin_hash) is not true then
    v_failures:=v_failures+1;update public.owners set login_failures=v_failures,login_locked_until=case when v_failures>=5 then v_now+interval '15 minutes' else null end where id=v_owner.id;
    return jsonb_build_object('ok',false,'code',case when v_failures>=5 then 'locked' else 'invalid_credentials' end,
      'message',case when v_failures>=5 then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.' else '관리자와 PIN을 확인해주세요.' end);end if;
  update public.owners set login_failures=0,login_locked_until=null where id=v_owner.id;
  insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
  values(v_owner.id,v_owner.business_id,v_owner.property_id,omg_private.token_hash(v_token),'infinity'::timestamptz) returning * into v_session;
  return omg_private.owner_session_result(v_session.id)||jsonb_build_object('access_token',v_token);
end;
$function$

;
CREATE OR REPLACE FUNCTION public.start_account_admin_session(p_owner_id uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b text;p text;status text;link public.account_properties%rowtype;result jsonb;
begin
 select * into link from public.account_properties where user_id=auth.uid() for update;
 if not found then return jsonb_build_object('ok',false,'message','사업장 정보를 찾을 수 없습니다.');end if;
 select x.code,y.code,y.service_status into b,p,status from public.businesses x join public.properties y on y.business_id=x.id where y.id=link.property_id;
 if status in('suspended','cancelled') then return jsonb_build_object('ok',false,'code','service_unavailable','message','현재 이용이 정지된 사업장입니다. 운영자에게 문의해주세요.');end if;
 result:=public.start_admin_session(p_owner_id,p_pin,b,p);
 if coalesce((result->>'ok')::boolean,false) and link.first_admin_login_at is null then
  update public.account_properties set first_admin_login_at=now() where user_id=auth.uid();
  if exists(select 1 from omg_private.trial_codes where property_id=link.property_id and used_by=auth.uid()) then
   perform omg_private.emit_system_notice(link.property_id,'first_login','first-login');
  end if;
 end if;
 return result;
end$function$

;
CREATE OR REPLACE FUNCTION omg_private.can_manage_shared_property(p_token uuid, p_property uuid, p_scope text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_token) AND s.token_expires_at>clock_timestamp() AND o.active
 AND (s.property_id=p_property OR EXISTS(SELECT 1 FROM public.property_share_requests r WHERE r.requester_property_id=s.property_id AND r.target_property_id=p_property AND r.status='approved' AND p_scope=ANY(r.requested_permissions)))) $function$

;
