-- Administrator PIN sessions persist until explicit logout or revocation.
-- Do not revive previously expired/revoked sessions. Keep all existing token,
-- account-active, property and service authorization checks unchanged.
begin;

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

CREATE OR REPLACE FUNCTION public.start_owner_session(p_login_id text, p_pin text, p_business_code text DEFAULT 'omg'::text, p_property_code text DEFAULT 'seoul-station'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_owner public.owners%rowtype;
  v_session public.owner_sessions%rowtype;
  v_token uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_failures integer;
begin
  if btrim(coalesce(p_login_id, '')) = '' or p_pin is null
     or p_pin !~ '^[0-9]{6,8}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '사장 아이디와 PIN을 확인해주세요.');
  end if;
  select o.* into v_owner from public.owners o
  join public.properties p on p.id = o.property_id and p.business_id = o.business_id
  join public.businesses b on b.id = o.business_id
  where lower(o.login_id) = lower(btrim(p_login_id)) and o.active
    and b.code = p_business_code and p.code = p_property_code
  for update of o;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials',
      'message', '사장 아이디와 PIN을 확인해주세요.');
  end if;
  if v_owner.login_locked_until > v_now then
    return jsonb_build_object('ok', false, 'code', 'locked',
      'message', 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.');
  end if;
  v_failures := case when v_owner.login_locked_until is not null
    then 0 else v_owner.login_failures end;
  if omg_private.pin_matches(p_pin, v_owner.pin_hash) is not true then
    v_failures := v_failures + 1;
    update public.owners set login_failures = v_failures,
      login_locked_until = case when v_failures >= 5
        then v_now + interval '15 minutes' else null end
    where id = v_owner.id;
    return jsonb_build_object('ok', false,
      'code', case when v_failures >= 5 then 'locked' else 'invalid_credentials' end,
      'message', case when v_failures >= 5
        then 'PIN 입력이 여러 번 틀렸습니다. 15분 후 다시 시도해주세요.'
        else '사장 아이디와 PIN을 확인해주세요.' end);
  end if;
  update public.owners set login_failures = 0, login_locked_until = null
    where id = v_owner.id;
  insert into public.owner_sessions
    (owner_id, business_id, property_id, login_token_hash, token_expires_at)
  values (v_owner.id, v_owner.business_id, v_owner.property_id,
    omg_private.token_hash(v_token), 'infinity'::timestamptz)
  returning * into v_session;
  return omg_private.owner_session_result(v_session.id)
    || jsonb_build_object('access_token', v_token);
end;
$function$
;

CREATE OR REPLACE FUNCTION omg_private.owner_session_result(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- Older Android releases parse this field with java.time.Instant. Keep an ISO
  -- timestamp on the wire; the database is authoritative and uses infinity.
  select jsonb_build_object(
    'ok', true, 'session_id', s.id, 'owner_id', o.id,
    'employee_name', o.display_name, 'role', 'owner', 'session_kind', 'owner',
    'business_id', s.business_id, 'property_id', s.property_id,
    'property_name', p.name, 'timezone', p.timezone,
    'expires_at', case when s.token_expires_at = 'infinity'::timestamptz
      then to_jsonb('9999-12-31T23:59:59Z'::text) else to_jsonb(s.token_expires_at) end, 'status', 'active'
  )
  from public.owner_sessions s
  join public.owners o on o.id = s.owner_id
  join public.properties p on p.id = s.property_id
  where s.id = p_session_id;
$function$
;

-- Preserve currently signed-in administrators without requiring another login.
update public.owner_sessions s set token_expires_at = 'infinity'::timestamptz
where s.token_expires_at > clock_timestamp()
  and exists (select 1 from public.owners o where o.id = s.owner_id and o.active);

-- Existing push registrations carry their own copy of the old 12-hour deadline.
-- Upgrade only registrations still backed by an active administrator session.
update public.native_push_devices d set expires_at = s.token_expires_at
from public.owner_sessions s join public.owners o on o.id = s.owner_id
where d.session_hash = s.login_token_hash and o.active
  and s.token_expires_at = 'infinity'::timestamptz;

commit;
