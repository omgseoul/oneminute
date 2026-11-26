begin;
alter table omg_private.iot_connections drop constraint iot_connections_pin_strategy_check;
alter table omg_private.iot_connections add constraint iot_connections_pin_strategy_check check(pin_strategy in('phone','mobile','random','booking','beds_booking','random_1_6'));
alter table omg_private.iot_connections add column pin_strategy_secondary text not null default 'mobile' check(pin_strategy_secondary in('none','phone','mobile','random','booking','beds_booking','random_1_6'));
-- Preserve the former implicit phone -> mobile fallback and all other strategies.
update omg_private.iot_connections set pin_strategy_secondary='none' where pin_strategy<>'phone';
create or replace function omg_private.iot_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;c omg_private.iot_connections%rowtype;v jsonb;r jsonb;u jsonb;inv jsonb;rooms jsonb;begin
 a:=omg_private.guest_actor(p_token);
 if a is null or (a->>'kind') is distinct from 'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 도어락 설정 권한이 없습니다.';end if;
 if p_action='auth' then return jsonb_build_object('ok',true,'property_id',home);end if;
 insert into omg_private.iot_connections(property_id) values(home) on conflict do nothing;
 select * into c from omg_private.iot_connections where property_id=home for update;
 select x into inv from omg_private.online_connections oc cross join lateral jsonb_array_elements(oc.properties)x where oc.property_id=home and (x->>'id')::bigint=oc.beds_property_id;
 select coalesce(p.rooms,'[]') into rooms from public.properties p where p.id=home;
 if p_action in('save','toggle','disconnect') and exists(select 1 from omg_private.iot_jobs where property_id=home and status='working' and leased_until>now()) then raise exception '비밀번호 처리 중입니다. 잠시 후 다시 시도해주세요.';end if;
 if p_action='save' then
  if c.enabled then raise exception '연동 사용을 OFF로 바꾼 뒤 매칭과 시간을 수정해주세요.';end if;
  if jsonb_typeof(p_data->'mappings') is distinct from 'array' or jsonb_array_length(p_data->'mappings')>200 then raise exception '객실 매칭을 확인해주세요.';end if;
  if coalesce(p_data->>'pin_strategy','') not in('phone','mobile','random','booking','beds_booking','random_1_6') or (p_data ? 'pin_strategy_secondary' and coalesce(p_data->>'pin_strategy_secondary','') not in('none','phone','mobile','random','booking','beds_booking','random_1_6')) then raise exception '비밀번호 생성 방식을 확인해주세요.';end if;
  perform pg_advisory_xact_lock(628114); -- Serialize cross-property assignments.
  for v in select * from jsonb_array_elements(p_data->'mappings') loop
   if coalesce(v->>'kind','') not in('room','common') then raise exception '매칭 유형을 확인해주세요.';end if;
   if not exists(select 1 from jsonb_array_elements(c.locks)x where x->>'lockId'=v->>'lock_id') then raise exception '연결 계정의 도어락을 선택해주세요.';end if;
   if coalesce(v->>'kind','room')<>'common' then
    if not rooms ? (v->>'room_name') then raise exception '이 사업장에 등록된 객실을 선택해주세요.';end if;
    if not exists(select 1 from jsonb_array_elements(inv->'roomTypes') t cross join lateral jsonb_array_elements(t->'units') un where t->>'id'=v->>'room_id' and un->>'id'=v->>'unit_id') then raise exception 'Beds24 객실과 유닛을 정확히 선택해주세요.';end if;
   end if;
   if exists(select 1 from omg_private.iot_connections oc cross join lateral jsonb_array_elements(oc.mappings)x where oc.property_id<>home and x->>'lock_id'=v->>'lock_id') then raise exception '이미 다른 지점에 매칭된 도어락입니다.';end if;
  end loop;
  if exists(select 1 from jsonb_array_elements(p_data->'mappings')x group by x->>'lock_id' having count(*)>1)
   or exists(select 1 from jsonb_array_elements(p_data->'mappings')x where x->>'kind'<>'common' group by x->>'room_id',x->>'unit_id' having count(*)>1)
   or exists(select 1 from jsonb_array_elements(p_data->'mappings')x where x->>'kind'<>'common' group by x->>'room_name' having count(*)>1) then raise exception '같은 도어락 또는 객실을 중복 매칭할 수 없습니다.';end if;
  update omg_private.iot_connections set mappings=p_data->'mappings',pin_strategy=p_data->>'pin_strategy',pin_strategy_secondary=case when p_data ? 'pin_strategy_secondary' then p_data->>'pin_strategy_secondary' else c.pin_strategy_secondary end,pin_length=(p_data->>'pin_length')::int,days_before=(p_data->>'days_before')::int,create_time=(p_data->>'create_time')::time,start_time=(p_data->>'start_time')::time,end_time=(p_data->>'end_time')::time,revision=revision+1,updated_at=now() where property_id=home;
 elsif p_action='toggle' then
  if (p_data->>'enabled')::boolean then
   if c.vault_id is null or not exists(select 1 from jsonb_array_elements(c.mappings)x where x->>'kind'='room') then raise exception 'TTLock 계정 연결과 객실 매칭을 먼저 완료해주세요.';end if;
   if not exists(select 1 from omg_private.iot_platform_config where singleton and enabled and vault_id is not null) then raise exception '운영센터의 TTLock 연결을 확인해주세요.';end if;
   if not exists(select 1 from omg_private.online_connections where property_id=home and vault_id is not null and beds_property_id is not null) then raise exception 'Beds24를 먼저 연결해주세요.';end if;
   if not coalesce((p_data->>'beds24_disabled')::boolean,false) then raise exception 'Beds24의 해당 객실 TTLock 자동발급을 중지한 후 켜주세요.';end if;
  end if;
  update omg_private.iot_connections set enabled=(p_data->>'enabled')::boolean,updated_at=now() where property_id=home;
 elsif p_action='retry' then
  update omg_private.iot_jobs set status='waiting',next_at=now(),attempt=0,revision=revision+1,error=null where id=(p_data->>'job_id')::uuid and property_id=home and status='failed';
  if not found then raise exception '재시도할 예약을 찾지 못했습니다.';end if;
 elsif p_action='disconnect' then
  if c.enabled or exists(select 1 from omg_private.iot_jobs where property_id=home and status<>'revoked' and state ? 'grants' and jsonb_array_length(state->'grants')>0) then raise exception '등록된 예약용 비밀번호가 남아 있습니다. 사용 종료와 정리를 확인한 후 연결을 해제해주세요.';end if;
  delete from vault.secrets where id=c.vault_id;
  update omg_private.iot_connections set vault_id=null,username=null,tt_uid=null,locks='[]',mappings='[]',enabled=false where property_id=home;
 elsif p_action<>'get' then raise exception '지원하지 않는 요청입니다.';end if;
 select * into c from omg_private.iot_connections where property_id=home;
 return jsonb_build_object('ok',true,'property_id',home,'property_name',(select name from public.properties where id=home),'timezone',(select timezone from public.properties where id=home),
 'provider_ready',exists(select 1 from omg_private.iot_platform_config where vault_id is not null and enabled),'connected',c.vault_id is not null,
 'settings',to_jsonb(c)-'vault_id'-'tt_uid','rooms',rooms,'inventory',coalesce(inv->'roomTypes','[]'),
 'jobs',(select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc),'[]') from(select j.id,j.booking_id,j.status,j.error,j.due_at,j.updated_at,j.replaced,b.guest_name,b.room_name,b.arrival,b.departure from omg_private.iot_jobs j left join omg_private.online_bookings b on b.property_id=j.property_id and b.id=j.booking_id where j.property_id=home order by j.updated_at desc limit 100)x));
end$$;

revoke all on function omg_private.iot_owner(uuid,text,jsonb) from public,anon,authenticated;
commit;
