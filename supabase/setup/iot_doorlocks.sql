begin;
-- All credentials and access codes are private. Browser calls go through the Edge
-- function and an independently authorized, service-role-only RPC.
create table omg_private.iot_platform_config (
 singleton boolean primary key default true check(singleton), vault_id uuid,
 client_id text, enabled boolean not null default true, monthly_limit int not null default 30000 check(monthly_limit between 1 and 10000000),
 updated_at timestamptz not null default now()
);
insert into omg_private.iot_platform_config(singleton) values(true);
create table omg_private.iot_connections (
 property_id uuid primary key references public.properties(id), vault_id uuid, username text, tt_uid bigint,
 enabled boolean not null default false, locks jsonb not null default '[]', mappings jsonb not null default '[]',
 pin_strategy text not null default 'phone' check(pin_strategy in('phone','random','booking','beds_booking','random_1_6')), pin_length int not null default 4 check(pin_length between 4 and 9),
 days_before int not null default 1 check(days_before between 0 and 30), create_time time not null default '09:00',
 start_time time not null default '15:00', end_time time not null default '11:00', revision int not null default 1,
 connected_at timestamptz, updated_at timestamptz not null default now()
);
create table omg_private.iot_api_usage (
 app_key text not null, month date not null, property_key text not null, calls int not null default 0,
 primary key(app_key,month,property_key)
);
create table omg_private.iot_jobs (
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id), booking_id bigint not null,
 fingerprint text not null, due_at timestamptz not null, valid_from timestamptz not null, valid_until timestamptz not null,
 status text not null default 'waiting' check(status in('waiting','working','done','failed','revoked')),
 revision int not null default 1, attempt int not null default 0, next_at timestamptz not null default now(),
 lease uuid, leased_until timestamptz, state jsonb not null default '{}', error text, replaced boolean not null default false,
 updated_at timestamptz not null default now(), unique(property_id,booking_id)
);
create index iot_jobs_pending on omg_private.iot_jobs(next_at) where status in('waiting','working');
create table omg_private.iot_notices (
 id uuid primary key default gen_random_uuid(), job_id uuid not null references omg_private.iot_jobs(id), revision int not null,
 kind text not null, message_id uuid, pushed_at timestamptz, created_at timestamptz not null default now(), unique(job_id,revision,kind)
);
alter table omg_private.iot_platform_config enable row level security;
alter table omg_private.iot_connections enable row level security;
alter table omg_private.iot_api_usage enable row level security;
alter table omg_private.iot_jobs enable row level security;
alter table omg_private.iot_notices enable row level security;
revoke all on omg_private.iot_platform_config,omg_private.iot_connections,omg_private.iot_api_usage,omg_private.iot_jobs,omg_private.iot_notices from public,anon,authenticated;

create function omg_private.iot_notice(p_job uuid,p_kind text) returns void language plpgsql security definer set search_path='' as $$
declare j omg_private.iot_jobs%rowtype;b omg_private.online_bookings%rowtype;p public.properties%rowtype;nid uuid;mid uuid;body text;begin
 select * into j from omg_private.iot_jobs where id=p_job;
 insert into omg_private.iot_notices(job_id,revision,kind) values(j.id,j.revision,p_kind) on conflict do nothing returning id into nid;
 if nid is null then return;end if;
 select * into b from omg_private.online_bookings where property_id=j.property_id and id=j.booking_id;
 select * into p from public.properties where id=j.property_id;
 body:='[IOT 도어락 '||case when p_kind='failed' then '처리 실패' when p_kind='revoked' then '사용 종료' else '비밀번호 등록 완료' end||']'||E'\n'||p.name||' · 객실 '||coalesce(b.room_name,'미정')
 ||E'\n게스트: '||coalesce(b.guest_name,'이름 미등록')||E'\n예약 #'||j.booking_id||coalesce(' · 예약사이트 번호 '||nullif(b.data->>'apiReference',''),'')
 ||E'\n숙박: '||coalesce(b.arrival::text,'미정')||' ~ '||coalesce(b.departure::text,'미정')||E'\n'
 ||case when p_kind='failed' then coalesce(j.error,'처리 결과를 확인해주세요.')||E'\nProperty > IOT 도어락 연동에서 해당 예약을 확인하고 재시도해주세요.'
 when p_kind='revoked' then '예약 취소 또는 숙박 종료로 OMS 예약용 비밀번호를 삭제했습니다.'
 else 'OMS가 생성한 비밀번호를 도어락과 Beds24 LOCK_PIN에 등록했습니다.' end;
 insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
 values(p.business_id,p.id,'system',left(body,2000),'normal','general','iot_lock',nid::text) returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_type,owner_id,recipient_key)
 select mid,'owner',o.id,'owner:'||o.id from public.owners o where omg_private.auto_message_owner_eligible(p.id,o.id);
 update omg_private.iot_notices set message_id=mid where id=nid;
end$$;

create function omg_private.iot_platform(p_user uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.iot_platform_config%rowtype;sid uuid;used bigint;m date:=date_trunc('month',now() at time zone 'UTC')::date;begin
 if p_user is null or not coalesce(omg_private.is_platform_administrator(p_user),false) then raise exception 'OMS 운영자 권한이 필요합니다.';end if;
 select * into c from omg_private.iot_platform_config where singleton for update;
 if p_action='save' then
  if length(coalesce(p_data->>'client_id','')) not between 8 and 128 or length(coalesce(p_data->>'client_secret','')) not between 8 and 256 then raise exception 'Client ID와 Client Secret을 확인해주세요.';end if;
  if c.client_id is distinct from p_data->>'client_id' and exists(select 1 from omg_private.iot_connections where vault_id is not null) then raise exception '다른 앱으로 변경하려면 각 지점의 TTLock 연결을 먼저 해제해주세요.';end if;
  sid:=c.vault_id;
  if sid is null then sid:=vault.create_secret(jsonb_build_object('clientId',p_data->>'client_id','clientSecret',p_data->>'client_secret')::text,'oms_ttlock_app');
  else perform vault.update_secret(sid,jsonb_build_object('clientId',p_data->>'client_id','clientSecret',p_data->>'client_secret')::text);end if;
  update omg_private.iot_platform_config set vault_id=sid,client_id=p_data->>'client_id',updated_at=now() where singleton;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(p_user,'ttlock_app_saved','{}');
 elsif p_action='toggle' then
  update omg_private.iot_platform_config set enabled=(p_data->>'enabled')::boolean,updated_at=now() where singleton;
 elsif p_action<>'status' then raise exception '지원하지 않는 요청입니다.';end if;
 select * into c from omg_private.iot_platform_config where singleton;
 select coalesce(sum(calls),0) into used from omg_private.iot_api_usage where app_key=md5(c.client_id) and month=m;
 return jsonb_build_object('ok',true,'configured',c.vault_id is not null,'enabled',c.enabled,'client_id',c.client_id,'updated_at',c.updated_at,
 'usage',jsonb_build_object('month',m,'used',used,'limit',c.monthly_limit,'remaining',greatest(0,c.monthly_limit-used),'timezone','UTC'),
 'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'used',u.calls) order by u.calls desc),'[]') from omg_private.iot_api_usage u left join public.properties p on p.id::text=u.property_key where u.app_key=md5(c.client_id) and u.month=m));
end$$;

create function omg_private.iot_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
  update omg_private.iot_connections set mappings=p_data->'mappings',pin_strategy=p_data->>'pin_strategy',pin_length=(p_data->>'pin_length')::int,days_before=(p_data->>'days_before')::int,create_time=(p_data->>'create_time')::time,start_time=(p_data->>'start_time')::time,end_time=(p_data->>'end_time')::time,revision=revision+1,updated_at=now() where property_id=home;
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

create function omg_private.iot_scan() returns void language plpgsql security definer set search_path='' as $$
begin
 update omg_private.iot_jobs set status='waiting',lease=null,next_at=now(),error='처리 결과를 다시 확인합니다.' where status='working' and leased_until<now();
 insert into omg_private.iot_jobs(property_id,booking_id,fingerprint,due_at,valid_from,valid_until)
 select c.property_id,b.id,md5(jsonb_build_array(b.arrival,b.departure,b.status,b.data->'roomId',b.data->'unitId',c.revision)::text),
 (b.arrival-c.days_before+c.create_time) at time zone coalesce(p.timezone,'Asia/Seoul'),
 (b.arrival+c.start_time) at time zone coalesce(p.timezone,'Asia/Seoul'),(b.departure+c.end_time) at time zone coalesce(p.timezone,'Asia/Seoul')
 from omg_private.iot_connections c join public.properties p on p.id=c.property_id join omg_private.online_bookings b on b.property_id=c.property_id
 where c.enabled and b.status in('new','confirmed') and b.departure>=(now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date and b.arrival<=(now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date+c.days_before
 and exists(select 1 from jsonb_array_elements(c.mappings)x where x->>'kind'='room' and x->>'room_id'=b.data->>'roomId')
 on conflict(property_id,booking_id) do nothing;
 update omg_private.iot_jobs j set status='waiting',next_at=now(),attempt=0,revision=j.revision+1,
 fingerprint=md5(jsonb_build_array(b.arrival,b.departure,b.status,b.data->'roomId',b.data->'unitId',c.revision)::text),
 due_at=(b.arrival-c.days_before+c.create_time) at time zone coalesce(p.timezone,'Asia/Seoul'),
 valid_from=(b.arrival+c.start_time) at time zone coalesce(p.timezone,'Asia/Seoul'),valid_until=(b.departure+c.end_time) at time zone coalesce(p.timezone,'Asia/Seoul')
 from omg_private.online_bookings b,omg_private.iot_connections c,public.properties p
 where j.property_id=b.property_id and j.booking_id=b.id and c.property_id=j.property_id and p.id=c.property_id and c.enabled and j.status<>'working'
 and b.arrival is not null and b.departure is not null
 and j.fingerprint<>md5(jsonb_build_array(b.arrival,b.departure,b.status,b.data->'roomId',b.data->'unitId',c.revision)::text);
 update omg_private.iot_jobs j set status='waiting',next_at=now(),attempt=0,revision=j.revision+1 from omg_private.iot_connections c
 where c.property_id=j.property_id and c.enabled and j.status='done' and j.valid_until<now();
end$$;

create function omg_private.iot_internal(p_action text,p_property uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.iot_connections%rowtype;pc omg_private.iot_platform_config%rowtype;j omg_private.iot_jobs%rowtype;sid uuid;m date:=date_trunc('month',now() at time zone 'UTC')::date;used bigint;begin
 if p_action='api_reserve' then
  select * into pc from omg_private.iot_platform_config where singleton for update;
  if pc.vault_id is null or not pc.enabled then raise exception '운영센터에서 TTLock API를 등록하고 사용을 켜주세요.';end if;
  select coalesce(sum(calls),0) into used from omg_private.iot_api_usage where app_key=md5(pc.client_id) and month=m;
  if used>=pc.monthly_limit then raise exception 'TTLock 월 API 호출 한도에 도달했습니다. 운영자에게 문의해주세요.';end if;
  insert into omg_private.iot_api_usage(app_key,month,property_key,calls) values(md5(pc.client_id),m,coalesce(p_property::text,'platform'),1)
  on conflict(app_key,month,property_key) do update set calls=iot_api_usage.calls+1;
  return (select decrypted_secret::jsonb from vault.decrypted_secrets where id=pc.vault_id);
 elsif p_action='claim' then
  perform omg_private.iot_scan();
  if not exists(select 1 from omg_private.iot_platform_config where enabled and vault_id is not null) then return jsonb_build_object('empty',true);end if;
  -- One worker per property avoids concurrent shared-door code reservations.
  select * into c from omg_private.iot_connections co where co.enabled and co.vault_id is not null
   and not exists(select 1 from omg_private.iot_jobs x where x.property_id=co.property_id and x.status='working')
   and exists(select 1 from omg_private.iot_jobs x where x.property_id=co.property_id and x.status='waiting' and x.next_at<=now() and (x.due_at<=now() or x.state ? 'grants'))
   order by co.updated_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  select * into j from omg_private.iot_jobs where property_id=c.property_id and status='waiting' and next_at<=now() and (due_at<=now() or state ? 'grants') order by next_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  update omg_private.iot_jobs set status='working',lease=gen_random_uuid(),leased_until=now()+interval '4 minutes',attempt=attempt+1,updated_at=now() where id=j.id returning * into j;
  update omg_private.iot_connections set updated_at=now() where property_id=c.property_id;
  return to_jsonb(j)||jsonb_build_object('settings',to_jsonb(c)-'vault_id','timezone',(select timezone from public.properties where id=c.property_id));
 elsif p_action='pushes' then return coalesce((select jsonb_agg(to_jsonb(x)) from(select id,message_id from omg_private.iot_notices where pushed_at is null and message_id is not null order by created_at limit 20)x),'[]');
 elsif p_action='pushed' then update omg_private.iot_notices set pushed_at=now() where id=(p_data->>'id')::uuid;return jsonb_build_object('ok',true);
 end if;
 select * into c from omg_private.iot_connections where property_id=p_property;
 if p_action='credentials' then return jsonb_build_object('secret',(select decrypted_secret::jsonb from vault.decrypted_secrets where id=c.vault_id),'settings',to_jsonb(c)-'vault_id');
 elsif p_action='connect' then
  select * into c from omg_private.iot_connections where property_id=p_property for update;
  if c.enabled or exists(select 1 from omg_private.iot_jobs where property_id=p_property and status='working') then raise exception '연동을 OFF로 바꾼 후 연결해주세요.';end if;
  if c.tt_uid is not null and c.tt_uid<>(p_data->'secret'->>'uid')::bigint and exists(select 1 from omg_private.iot_jobs where property_id=p_property and status<>'revoked' and state ? 'grants') then raise exception '기존 계정의 예약용 비밀번호를 먼저 정리해주세요.';end if;
  sid:=c.vault_id;
  if sid is null then sid:=vault.create_secret((p_data->'secret')::text,'oms_ttlock_'||p_property);else perform vault.update_secret(sid,(p_data->'secret')::text);end if;
  update omg_private.iot_connections set vault_id=sid,username=p_data->>'username',tt_uid=(p_data->'secret'->>'uid')::bigint,locks=p_data->'locks',mappings=case when tt_uid is distinct from (p_data->'secret'->>'uid')::bigint then '[]'::jsonb else mappings end,connected_at=now(),updated_at=now() where property_id=p_property;
 elsif p_action='token' then perform vault.update_secret(c.vault_id,(p_data->'secret')::text);
 elsif p_action='locks' then update omg_private.iot_connections set locks=p_data->'locks',updated_at=now() where property_id=p_property;
 elsif p_action in('checkpoint','gate','finish','observe') then
  select * into j from omg_private.iot_jobs where id=(p_data->>'id')::uuid and property_id=p_property for update;
  if not found or j.status<>'working' or j.lease is distinct from (p_data->>'lease')::uuid or j.leased_until<now() then raise exception '도어락 작업 잠금이 만료되었습니다. 재확인합니다.';end if;
  if not c.enabled or not exists(select 1 from omg_private.iot_platform_config where enabled) then raise exception '도어락 연동이 중지되었습니다.';end if;
  if p_action='observe' then
   if (p_data->'booking'->>'id')::bigint<>j.booking_id or (p_data->'booking'->>'propertyId')::bigint is distinct from (select beds_property_id from omg_private.online_connections where property_id=p_property) then raise exception '예약 지점이 변경되었습니다.';end if;
   update omg_private.online_bookings set arrival=(p_data->'booking'->>'arrival')::date,departure=(p_data->'booking'->>'departure')::date,status=p_data->'booking'->>'status',
    guest_name=trim(coalesce(p_data->'booking'->>'firstName','')||' '||coalesce(p_data->'booking'->>'lastName','')),
    room_name=coalesce((select x->>'room_name' from jsonb_array_elements(c.mappings)x where x->>'kind'='room' and x->>'room_id'=p_data->'booking'->>'roomId' and x->>'unit_id'=p_data->'booking'->>'unitId' limit 1),p_data->'booking'->>'roomName',room_name),
    data=data||jsonb_build_object('roomId',p_data->'booking'->'roomId','unitId',p_data->'booking'->'unitId','apiReference',p_data->'booking'->'apiReference')
    where property_id=p_property and id=j.booking_id;
   update omg_private.iot_jobs j2 set fingerprint=md5(jsonb_build_array(b.arrival,b.departure,b.status,b.data->'roomId',b.data->'unitId',c.revision)::text),
    due_at=(b.arrival-c.days_before+c.create_time) at time zone coalesce(p.timezone,'Asia/Seoul'),valid_from=(b.arrival+c.start_time) at time zone coalesce(p.timezone,'Asia/Seoul'),valid_until=(b.departure+c.end_time) at time zone coalesce(p.timezone,'Asia/Seoul')
    from omg_private.online_bookings b,public.properties p where j2.id=j.id and b.property_id=p_property and b.id=j.booking_id and p.id=p_property;
  elsif p_action='checkpoint' then update omg_private.iot_jobs set state=p_data->'state',replaced=replaced or coalesce((p_data->>'replaced')::boolean,false),leased_until=now()+interval '4 minutes',updated_at=now() where id=j.id;
  elsif p_action='finish' then
   if p_data->>'status' not in('done','failed','revoked','waiting') then raise exception '잘못된 처리 상태입니다.';end if;
   update omg_private.iot_jobs set status=p_data->>'status',error=left(p_data->>'error',600),next_at=coalesce((p_data->>'next_at')::timestamptz,now()+interval '5 minutes'),lease=null,leased_until=null,updated_at=now() where id=j.id;
   if p_data->>'status' in('done','failed','revoked') then perform omg_private.iot_notice(j.id,p_data->>'status');end if;
  end if;
 else raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true);
end$$;

create function public.iot_platform(p_user uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.iot_platform(p_user,p_action,p_data)$$;
create function public.iot_owner(p_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.iot_owner(p_token,p_action,p_data)$$;
create function public.iot_internal(p_action text,p_property uuid default null,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.iot_internal(p_action,p_property,p_data)$$;
revoke all on function public.iot_platform(uuid,text,jsonb),public.iot_owner(uuid,text,jsonb),public.iot_internal(text,uuid,jsonb),omg_private.iot_platform(uuid,text,jsonb),omg_private.iot_owner(uuid,text,jsonb),omg_private.iot_internal(text,uuid,jsonb),omg_private.iot_notice(uuid,text),omg_private.iot_scan() from public,anon,authenticated;
grant execute on function public.iot_platform(uuid,text,jsonb),public.iot_owner(uuid,text,jsonb),public.iot_internal(text,uuid,jsonb),omg_private.iot_platform(uuid,text,jsonb),omg_private.iot_owner(uuid,text,jsonb),omg_private.iot_internal(text,uuid,jsonb) to service_role;
-- Reuse the existing bot channel with recipient authorization checked again at push time.
create function omg_private.iot_push_dispatch(p_message_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.property_messages%rowtype;mode text;name text;modes jsonb;begin
 select * into m from public.property_messages where id=p_message_id and source='iot_lock';if not found then return jsonb_build_object('ok',false);end if;
 select coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림') into mode,name from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=m.property_id;
 select coalesce(jsonb_object_agg('property_'||p.management_number||'_owner_'||o.id,mode),'{}') into modes from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id where r.message_id=m.id and omg_private.auto_message_owner_eligible(m.property_id,o.id);
 return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'sender_label',name||' · 도어락','recipient_modes',modes,'recipient_topics',(select coalesce(jsonb_agg(k),'[]') from jsonb_object_keys(modes)x(k)));
end$$;
revoke all on function omg_private.iot_push_dispatch(uuid) from public,anon,authenticated;
do $migration$ declare f text;signature text;needle text;begin
 f:=pg_get_functiondef('public.get_briefing_push_dispatch(uuid)'::regprocedure);
 needle:=$n$ select * into m from public.property_messages where id=p_message_id and source='bot_briefing';$n$;
 if strpos(f,needle)=0 then raise exception 'Missing bot dispatch guard';end if;
 execute replace(f,needle,$n$ if exists(select 1 from public.property_messages where id=p_message_id and source='iot_lock') then return omg_private.iot_push_dispatch(p_message_id);end if;
$n$||needle);
 for signature in select unnest(array['public.list_property_messages(uuid)','public.list_notification_bot_messages(uuid,timestamptz,uuid)']) loop
  f:=pg_get_functiondef(signature::regprocedure);needle:=$n$when m.sender_type='system' then '근태관리'$n$;
  if strpos(f,needle)=0 then raise exception 'Missing notification label guard';end if;
  execute replace(f,needle,$n$when m.source='iot_lock' then '도어락' $n$||needle);
 end loop;
end$migration$;
select cron.schedule('oms-iot-doorlocks','* * * * *',$cron$
 select net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/iot-locks/worker',headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='oms_guest_ai_worker_secret')),body:='{}'::jsonb,timeout_milliseconds:=1000)
 where exists(select 1 from omg_private.iot_connections where enabled) or exists(select 1 from omg_private.iot_notices where pushed_at is null);
$cron$);
commit;
