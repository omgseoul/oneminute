-- Translation character allowances, provider credentials and auditable previews.
begin;
alter table omg_private.service_plans add column if not exists translation_limit bigint not null default 50000 check(translation_limit between 0 and 100000000);
alter table public.properties add column if not exists translation_limit_override bigint check(translation_limit_override between 0 and 100000000);
alter table omg_private.online_connections add column if not exists translation_checked_at timestamptz,add column if not exists translation_key_status text not null default 'unchecked';
alter table omg_private.online_outbox add column if not exists original_body text,add column if not exists translation_id uuid,add column if not exists target_language text;
create table if not exists omg_private.translation_provider(singleton boolean primary key default true check(singleton),vault_id uuid,key_status text not null default 'unconfigured',checked_at timestamptz,key_suffix text,enabled boolean not null default true);
insert into omg_private.translation_provider(singleton)values(true)on conflict do nothing;
create table if not exists omg_private.translation_usage(property_id uuid not null references public.properties(id) on delete cascade,month date not null,used bigint not null default 0,reserved bigint not null default 0,personal bigint not null default 0,primary key(property_id,month),check(used>=0 and reserved>=0 and personal>=0));
create table if not exists omg_private.translation_jobs(id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id) on delete cascade,booking_id bigint not null,message_id bigint,body text not null,body_hash text not null,target text not null,direction text not null check(direction in('incoming','outgoing')),translated text,source_language text,provider text check(provider in('platform','personal')),month date,chars int not null,status text not null default 'pending',lease uuid,leased_until timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(property_id,booking_id,body_hash,target,direction));
-- Preserve successful translations made before allowance accounting.
insert into omg_private.translation_jobs(property_id,booking_id,message_id,body,body_hash,target,direction,translated,chars,status)
select m.property_id,m.booking_id,m.id,m.body,md5(m.body),'ko','incoming',t.translated,length(m.body),'done' from omg_private.online_translations t join omg_private.online_messages m on m.property_id=t.property_id and m.id=t.message_id where t.translated is not null and t.body_hash=md5(m.body) on conflict do nothing;
create index if not exists translation_jobs_pending on omg_private.translation_jobs(property_id,leased_until) where status='processing';
alter table omg_private.translation_provider enable row level security;
alter table omg_private.translation_usage enable row level security;
alter table omg_private.translation_jobs enable row level security;
revoke all on omg_private.translation_provider,omg_private.translation_usage,omg_private.translation_jobs from public,anon,authenticated;

create or replace function omg_private.translation_summary(prop uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('month',to_char(date_trunc('month',now() at time zone 'Asia/Seoul'),'YYYY-MM'),'limit',coalesce(p.translation_limit_override,sp.translation_limit,50000),'used',coalesce(u.used,0),'reserved',coalesce(u.reserved,0),'personal_used',coalesce(u.personal,0),'remaining',greatest(0,coalesce(p.translation_limit_override,sp.translation_limit,50000)-coalesce(u.used,0)-coalesce(u.reserved,0)),
 'warn',coalesce(u.used,0)>=coalesce(p.translation_limit_override,sp.translation_limit,50000)*0.8 and coalesce(p.translation_limit_override,sp.translation_limit,50000)>0,'full',coalesce(u.used,0)>=coalesce(p.translation_limit_override,sp.translation_limit,50000),
 'personal_connected',co.translation_vault_id is not null,'personal_status',coalesce(co.translation_key_status,'unconfigured'),'personal_checked_at',co.translation_checked_at,'platform_ready',tp.enabled and tp.vault_id is not null and tp.key_status='valid')
 from public.properties p left join omg_private.service_plans sp on sp.code=p.service_plan left join omg_private.translation_usage u on u.property_id=p.id and u.month=date_trunc('month',now() at time zone 'Asia/Seoul')::date left join omg_private.online_connections co on co.property_id=p.id cross join omg_private.translation_provider tp where p.id=prop
$$;
revoke all on function omg_private.translation_summary(uuid) from public,anon,authenticated;

-- Service-only entry: Edge authenticates the account before asking for scoped secrets.
create or replace function public.translation_control(p_action text,p_property uuid default null,p_user uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid;s jsonb;j omg_private.translation_jobs%rowtype;m omg_private.online_messages%rowtype;v_body text;v_target text;v_book bigint;v_dir text;v_hash text;k text;v_provider text;v_month date:=date_trunc('month',now() at time zone 'Asia/Seoul')::date;v_limit bigint;v_used bigint;v_reserved bigint;v_old record;begin
 if p_action like 'platform_%' then
  if p_user is null or not omg_private.is_platform_administrator(p_user) then raise exception '운영센터 권한이 필요합니다.';end if;
 end if;
 if p_action in('platform_save','save_key') then
  if length(coalesce(p_data->>'key','')) not between 20 and 300 then raise exception '번역 API 키를 확인해주세요.';end if;
  if p_action='platform_save' then
   select vault_id into sid from omg_private.translation_provider where singleton for update;
   if sid is null then sid:=vault.create_secret(p_data->>'key','oms_translation_platform','OMS shared translation');else perform vault.update_secret(sid,p_data->>'key');end if;
   update omg_private.translation_provider set vault_id=sid,key_suffix=right(p_data->>'key',4),key_status='valid',checked_at=now() where singleton;
  else
   select translation_vault_id into sid from omg_private.online_connections where property_id=p_property for update;
   if not found then raise exception '지점 설정이 없습니다.';end if;
   if sid is null then sid:=vault.create_secret(p_data->>'key','oms_translate_'||p_property,'Google Cloud Translation Basic');else perform vault.update_secret(sid,p_data->>'key');end if;
   update omg_private.online_connections set translation_vault_id=sid,translation_key_status='valid',translation_checked_at=now() where property_id=p_property;
  end if;
 elsif p_action='platform_enabled' then update omg_private.translation_provider set enabled=coalesce((p_data->>'enabled')::boolean,false) where singleton;
 elsif p_action in('platform_key','personal_key') then
  select decrypted_secret into k from vault.decrypted_secrets where id=case when p_action='platform_key' then (select vault_id from omg_private.translation_provider where singleton) else (select translation_vault_id from omg_private.online_connections where property_id=p_property) end;
  return jsonb_build_object('key',k,'fingerprint',md5(k));
 elsif p_action in('platform_check_result','personal_check_result') then
  -- Fingerprint prevents a concurrent old-key check from invalidating a newly saved key.
  if p_action='platform_check_result' then update omg_private.translation_provider tp set key_status=p_data->>'status',checked_at=now() where singleton and exists(select 1 from vault.decrypted_secrets v where v.id=tp.vault_id and md5(v.decrypted_secret)=p_data->>'fingerprint');
  else update omg_private.online_connections co set translation_key_status=p_data->>'status',translation_checked_at=now() where property_id=p_property and exists(select 1 from vault.decrypted_secrets v where v.id=co.translation_vault_id and md5(v.decrypted_secret)=p_data->>'fingerprint');end if;
 elsif p_action='remove_key' then
  select translation_vault_id into sid from omg_private.online_connections where property_id=p_property for update;
  update omg_private.online_connections set translation_vault_id=null,translation_key_status='unconfigured',translation_checked_at=null where property_id=p_property;
  delete from vault.secrets where id=sid;
 elsif p_action='latest_guest' then
  select * into m from omg_private.online_messages where property_id=p_property and booking_id=(p_data->>'booking_id')::bigint and source='guest' and length(btrim(body))>0 order by sent_at desc,id desc limit 1;
  return jsonb_build_object('message_id',m.id);
 elsif p_action='claim' then
  v_dir:=coalesce(p_data->>'direction','incoming');v_target:=coalesce(p_data->>'target','ko');
  if v_target !~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$' or v_dir not in('incoming','outgoing') then raise exception '번역 언어를 확인해주세요.';end if;
  if v_dir='incoming' then
   select * into m from omg_private.online_messages where property_id=p_property and id=(p_data->>'message_id')::bigint and source='guest';
   if not found then raise exception '수신 메시지를 찾을 수 없습니다.';end if;v_body:=m.body;v_book:=m.booking_id;v_target:='ko';
  else
   v_body:=btrim(p_data->>'body');v_book:=(p_data->>'booking_id')::bigint;
   if not exists(select 1 from omg_private.online_bookings where property_id=p_property and id=v_book) then raise exception '예약정보를 확인해주세요.';end if;
  end if;
  if v_body is null or length(v_body) not between 1 and (case when v_dir='outgoing' then 4000 else 5000 end) then raise exception '번역할 내용의 길이를 확인해주세요.';end if;
  perform pg_advisory_xact_lock(hashtextextended('translation:'||p_property,812));
  -- A process lost after a provider call may already have incurred cost; settle its reservation once.
  for v_old in select * from omg_private.translation_jobs where property_id=p_property and status='processing' and leased_until<now() for update loop
   update omg_private.translation_usage set reserved=greatest(0,reserved-case when v_old.provider='platform' then v_old.chars else 0 end),used=used+case when v_old.provider='platform' then v_old.chars else 0 end,personal=personal+case when v_old.provider='personal' then v_old.chars else 0 end where property_id=p_property and month=v_old.month;
   update omg_private.translation_jobs set status='uncertain',updated_at=now() where id=v_old.id;
  end loop;
  v_hash:=md5(v_body);
  insert into omg_private.translation_jobs(property_id,booking_id,message_id,body,body_hash,target,direction,chars)values(p_property,v_book,m.id,v_body,v_hash,v_target,v_dir,length(v_body)) on conflict do nothing;
  select * into j from omg_private.translation_jobs where property_id=p_property and booking_id=v_book and body_hash=v_hash and target=v_target and direction=v_dir for update;
  if j.body is distinct from v_body then raise exception '번역 요청을 다시 확인해주세요.';end if;
  if j.status='done' then return jsonb_build_object('cached',true,'id',j.id,'text',j.translated,'source_language',j.source_language,'target',j.target,'usage',omg_private.translation_summary(p_property));end if;
  if j.leased_until>now() then return jsonb_build_object('busy',true);end if;
  s:=omg_private.translation_summary(p_property);v_limit:=(s->>'limit')::bigint;
  insert into omg_private.translation_usage(property_id,month)values(p_property,v_month)on conflict do nothing;
  select used,reserved into v_used,v_reserved from omg_private.translation_usage where property_id=p_property and month=v_month for update;
  if v_used+v_reserved+j.chars<=v_limit and (s->>'platform_ready')::boolean then
   v_provider:='platform';select v.decrypted_secret into k from vault.decrypted_secrets v join omg_private.translation_provider tp on tp.vault_id=v.id;
  else
   v_provider:='personal';select v.decrypted_secret into k from vault.decrypted_secrets v join omg_private.online_connections co on co.translation_vault_id=v.id where co.property_id=p_property and co.translation_key_status in('valid','unchecked');
  end if;
  if k is null then
   if v_used+v_reserved+j.chars>v_limit then return jsonb_build_object('limit_reached',true,'usage',s);end if;
   return jsonb_build_object('unconfigured',true,'usage',s);
  end if;
  update omg_private.translation_jobs set status='processing',provider=v_provider,month=v_month,lease=gen_random_uuid(),leased_until=now()+interval '60 seconds',updated_at=now() where id=j.id returning * into j;
  if v_provider='platform' then update omg_private.translation_usage set reserved=reserved+j.chars where property_id=p_property and month=v_month;end if;
  return jsonb_build_object('id',j.id,'lease',j.lease,'body',j.body,'target',j.target,'key',k,'provider',j.provider);
 elsif p_action='finish' then
  perform pg_advisory_xact_lock(hashtextextended('translation:'||p_property,812));
  select * into j from omg_private.translation_jobs where property_id=p_property and id=(p_data->>'id')::uuid and lease=(p_data->>'lease')::uuid for update;
  if not found or j.status<>'processing' then return jsonb_build_object('ok',true,'skip',true);end if;
  update omg_private.translation_usage set reserved=greatest(0,reserved-case when j.provider='platform' then j.chars else 0 end),used=used+case when j.provider='platform' and coalesce((p_data->>'charged')::boolean,false) then j.chars else 0 end,personal=personal+case when j.provider='personal' and coalesce((p_data->>'charged')::boolean,false) then j.chars else 0 end where property_id=p_property and month=j.month;
  update omg_private.translation_jobs set status=case when p_data->>'text' is not null then 'done' else 'failed' end,translated=p_data->>'text',source_language=p_data->>'source_language',leased_until=case when p_data->>'text' is null then now()+interval '20 seconds' else null end,updated_at=now() where id=j.id;
  s:=omg_private.translation_summary(p_property);
  if (s->>'warn')::boolean then perform omg_private.emit_system_notice(p_property,case when (s->>'full')::boolean then 'translation_full' else 'translation_warning' end,'translation:'||j.month||case when (s->>'full')::boolean then ':full' else ':warning' end);end if;
  return jsonb_build_object('ok',true,'usage',s);
 elsif p_action not in('status','platform_status') then raise exception '지원하지 않는 번역 요청입니다.';end if;
 if p_action like 'platform_%' then return jsonb_build_object('ok',true,'provider',(select jsonb_build_object('ready',vault_id is not null,'status',key_status,'checked_at',checked_at,'suffix',key_suffix,'enabled',enabled) from omg_private.translation_provider),'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'usage',omg_private.translation_summary(p.id)) order by p.name),'[]') from public.properties p));end if;
 return jsonb_build_object('ok',true,'usage',omg_private.translation_summary(p_property));
end$$;
revoke all on function public.translation_control(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.translation_control(text,uuid,uuid,jsonb) to service_role;

-- Preserve existing service calculations and permissions.
CREATE OR REPLACE FUNCTION omg_private.property_service_state(prop uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.properties%rowtype;c omg_private.service_policy%rowtype;used bigint;lim bigint;warn bigint;ends timestamptz;remaining int;expired boolean;
begin select * into p from public.properties where id=prop;if not found then return null;end if;
 select * into c from omg_private.service_policy where id;
 used:=omg_private.property_usage_bytes(prop);
 lim:=coalesce(p.service_storage_limit,case when p.service_status='trial' then c.storage_limit_bytes else (select storage_limit_bytes from omg_private.service_plans where code=p.service_plan) end,c.storage_limit_bytes);
 warn:=least(coalesce(p.service_storage_warning,c.storage_warning_bytes),lim);
 ends:=case when p.service_status='trial' then p.trial_ends_at else p.subscription_ends_at end;
 remaining:=ceil(extract(epoch from ends-now())/86400)::integer;
 expired:=not p.billing_exempt and ends is not null and now()>=ends;
 return jsonb_build_object('property_id',p.id,'property_name',p.name,'status',p.service_status,'plan',p.service_plan,'exempt',p.billing_exempt,
 'ends_at',ends,'days_left',remaining,'expired',expired,'remind',not p.billing_exempt and ends is not null and remaining<=c.reminder_days,
 'grace_days',c.grace_days,'restricted',not p.billing_exempt and expired and now()>=ends+make_interval(days=>c.grace_days) and c.end_action='restrict_writes',
 'used_bytes',used,'limit_bytes',lim,'warning_bytes',warn,'storage_warn',not p.billing_exempt and used>=warn,'storage_full',not p.billing_exempt and used>=lim,
 'storage_action',c.storage_action,'support_contact',c.support_contact,'usage_estimated',true,'translation',omg_private.translation_summary(prop),'checked_at',now());
end$function$
;
CREATE OR REPLACE FUNCTION public.platform_operations(p_action text DEFAULT 'get'::text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prop uuid;c omg_private.service_policy%rowtype;old jsonb;result jsonb;plan jsonb;name text;status text;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then
  return jsonb_build_object('ok',false,'code','platform_admin_required','message','OMS 운영자 권한이 필요합니다.');
 end if;
 if p_action='policy' then
  if jsonb_typeof(p_data->'plans') is distinct from 'array' then
   raise exception '요금제 목록을 확인해주세요.';
  end if;
  if jsonb_array_length(p_data->'plans')=0 then
   raise exception '요금제는 최소 1개 있어야 합니다.';
  end if;
  if exists(
   select 1 from omg_private.service_plans sp
   where not exists(select 1 from jsonb_array_elements(p_data->'plans') as plans(value) where value->>'code'=sp.code)
    and exists(select 1 from public.properties customer where customer.service_plan=sp.code)
  ) then
   raise exception '고객이 사용 중인 요금제는 삭제할 수 없습니다. 먼저 고객의 요금제를 변경해주세요.';
  end if;
  select to_jsonb(x) into old from omg_private.service_policy x where id;
  update omg_private.service_policy set trial_days=(p_data->>'trial_days')::int,reminder_days=(p_data->>'reminder_days')::int,grace_days=(p_data->>'grace_days')::int,
   storage_limit_bytes=(p_data->>'storage_limit_bytes')::bigint,storage_warning_bytes=(p_data->>'storage_warning_bytes')::bigint,
   end_action=p_data->>'end_action',storage_action=p_data->>'storage_action',support_contact=btrim(coalesce(p_data->>'support_contact','')),updated_at=now() where id;
  for plan in select value from jsonb_array_elements(p_data->'plans') as plans(value) loop
   insert into omg_private.service_plans(code,name,monthly_price,storage_limit_bytes,employee_limit,room_limit,translation_limit)
   values(plan->>'code',left(btrim(plan->>'name'),40),nullif(plan->>'monthly_price','')::integer,(plan->>'storage_limit_bytes')::bigint,coalesce((plan->>'employee_limit')::integer,(select employee_limit from omg_private.service_plans where code=plan->>'code'),10),coalesce((plan->>'room_limit')::integer,(select room_limit from omg_private.service_plans where code=plan->>'code'),10),coalesce((plan->>'translation_limit')::bigint,(select translation_limit from omg_private.service_plans where code=plan->>'code'),50000))
   on conflict(code) do update set name=excluded.name,monthly_price=excluded.monthly_price,storage_limit_bytes=excluded.storage_limit_bytes,employee_limit=excluded.employee_limit,room_limit=excluded.room_limit,translation_limit=excluded.translation_limit;
   if not found or btrim(plan->>'name')='' then raise exception '요금제 이름과 용량을 확인해주세요.';end if;
  end loop;
  delete from omg_private.service_plans sp
  where not exists(select 1 from jsonb_array_elements(p_data->'plans') as plans(value) where value->>'code'=sp.code);
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'service_policy_updated',jsonb_build_object('before',old,'after',p_data));
 elsif p_action='customer' then
  prop:=(p_data->>'property_id')::uuid;select service_status into status from public.properties where id=prop;
  if status is null then return jsonb_build_object('ok',false,'message','고객을 찾을 수 없습니다.');end if;
  if not exists(select 1 from omg_private.service_plans where code=p_data->>'service_plan') then raise exception '요금제를 확인해주세요.';end if;
  select to_jsonb(p) into old from public.properties p where id=prop;
  result:=public.update_platform_property(prop,coalesce(p_data->>'service_status',status),coalesce(p_data->>'operator_note',''));
  if not(result->>'ok')::boolean then return result;end if;
  update public.properties set service_plan=p_data->>'service_plan',billing_exempt=coalesce((p_data->>'billing_exempt')::boolean,false),
   trial_ends_at=nullif(p_data->>'trial_ends_at','')::timestamptz,subscription_ends_at=nullif(p_data->>'subscription_ends_at','')::timestamptz,
   translation_limit_override=case when p_data ? 'translation_limit_override' then nullif(p_data->>'translation_limit_override','')::bigint else translation_limit_override end,service_storage_limit=nullif(p_data->>'storage_limit_bytes','')::bigint,service_storage_warning=nullif(p_data->>'storage_warning_bytes','')::bigint where id=prop;
  if exists(select 1 from public.properties where id=prop and (service_storage_limit<1048576 or service_storage_warning<1 or service_storage_warning>service_storage_limit)) then raise exception '고객별 용량과 경고 기준을 확인해주세요.';end if;
  insert into public.platform_audit_logs(operator_user_id,property_id,action,detail) values(auth.uid(),prop,'customer_service_updated',jsonb_build_object('before',jsonb_build_object('plan',old->'service_plan','trial_ends_at',old->'trial_ends_at','subscription_ends_at',old->'subscription_ends_at','billing_exempt',old->'billing_exempt'),'after',p_data));
  perform omg_private.emit_system_notice(prop,'service_updated',gen_random_uuid()::text);
 elsif p_action not in('get','usage') then raise exception '지원하지 않는 요청입니다.';
 end if;
 result:=public.get_platform_dashboard();
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 perform omg_private.refresh_service_notices();
 select coalesce(jsonb_agg((x.value)||jsonb_build_object('trial_code',(select code from omg_private.trial_codes where property_id=p.id),'service_plan',p.service_plan,'billing_exempt',p.billing_exempt,'subscription_ends_at',p.subscription_ends_at,'translation_limit_override',p.translation_limit_override,'storage_limit_override',p.service_storage_limit,'storage_warning_override',p.service_storage_warning,'service',coalesce(n.state,omg_private.property_service_state(p.id))) order by p.management_number),'[]'::jsonb) into plan
 from jsonb_array_elements(result->'properties')x(value) join public.properties p on p.id=(x.value->>'property_id')::uuid left join omg_private.service_notices n on n.property_id=p.id;
 return result||jsonb_build_object('properties',plan,'policy',old,'plans',(select jsonb_agg(to_jsonb(x) order by code) from omg_private.service_plans x),'last_checked_at',(select max(checked_at) from omg_private.service_notices),'payment_connected',false);
end$function$
;
CREATE OR REPLACE FUNCTION omg_private.render_system_notice(value text, prop uuid, s jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result text:=value;days int;plan text;
begin
 select c.trial_days into days from omg_private.trial_codes c where c.property_id=prop;
 select name into plan from omg_private.service_plans where code=s->>'plan';
 result:=replace(result,'{사업장명}',coalesce(s->>'property_name',''));
 result:=replace(result,'{체험기간}',coalesce(days,(select trial_days from omg_private.service_policy where id))::text);
 result:=replace(result,'{제공용량}',omg_private.service_bytes((s->>'limit_bytes')::bigint));
 result:=replace(result,'{사용용량}',omg_private.service_bytes((s->>'used_bytes')::bigint));
 result:=replace(result,'{종료일}',coalesce(to_char((s->>'ends_at')::timestamptz at time zone 'Asia/Seoul','YYYY-MM-DD'),'기한 없음'));
 result:=replace(result,'{남은일수}',greatest(0,coalesce((s->>'days_left')::int,0))::text);
 result:=replace(result,'{요금제}',coalesce(plan,''));
 result:=replace(result,'{문의처}',coalesce(s->>'support_contact',''));
 result:=replace(result,'{번역제공량}',coalesce(s->'translation'->>'limit','0'));
 result:=replace(result,'{번역사용량}',coalesce(s->'translation'->>'used','0'));
 return result;
end$function$
;
CREATE OR REPLACE FUNCTION omg_private.refresh_service_notices()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p record;s jsonb;previous jsonb;cycle text;ends text;event text;
begin
 for p in select id,service_status from public.properties loop
  perform pg_advisory_xact_lock(hashtext('service-notice:'||p.id::text));
  select state into previous from omg_private.service_notices where property_id=p.id;
  s:=omg_private.property_service_state(p.id);
  -- Storage warnings recur only after the condition clears and a new episode begins.
  foreach event in array array['storage_warning','storage_full'] loop
   if coalesce((s->>case event when 'storage_full' then 'storage_full' else 'storage_warn' end)::boolean,false) and not (s->>'exempt')::boolean then
    cycle:=coalesce(previous->>(event||'_cycle'),gen_random_uuid()::text);
    s:=s||jsonb_build_object(event||'_cycle',cycle);
    if event='storage_full' or not(s->>'storage_full')::boolean then perform omg_private.emit_system_notice(p.id,event,event||':'||cycle);end if;
   end if;
  end loop;
  if not (s->>'exempt')::boolean and p.service_status in('trial','active') then
   ends:=s->>'ends_at';
   if (s->>'expired')::boolean then event:=case p.service_status when 'trial' then 'trial_expired' else 'subscription_expired' end;
   elsif (s->>'remind')::boolean then event:=case p.service_status when 'trial' then 'trial_expiring' else 'subscription_expiring' end;
   else event:=null;end if;
   if event is not null then perform omg_private.emit_system_notice(p.id,event,event||':'||ends);end if;
  end if;
  if (s->'translation'->>'warn')::boolean then
   event:=case when (s->'translation'->>'full')::boolean then 'translation_full' else 'translation_warning' end;
   perform omg_private.emit_system_notice(p.id,event,'translation:'||to_char(date_trunc('month',now() at time zone 'Asia/Seoul'),'YYYY-MM-DD')||case when event='translation_full' then ':full' else ':warning' end);
  end if;
  insert into omg_private.service_notices(property_id,state,checked_at) values(p.id,s,now()) on conflict(property_id) do update set state=excluded.state,checked_at=excluded.checked_at;
 end loop;
end$function$
;

alter table omg_private.system_notice_templates drop constraint if exists system_notice_templates_event_key_check;
alter table omg_private.system_notice_templates add constraint system_notice_templates_event_key_check check(event_key in('first_login','storage_warning','storage_full','trial_expiring','trial_expired','subscription_expiring','subscription_expired','service_updated','manual','translation_warning','translation_full'));
insert into omg_private.system_notice_templates(event_key,title,body)
select 'translation_warning','번역 제공량 80% 사용','{사업장명}의 이번 달 번역 사용량은 {번역사용량} / {번역제공량}자입니다. 기본 제공량 이상으로 사용하려면 온라인 관리 > 기본정보에 개인 Google 번역 API 키를 등록해주세요.' where not exists(select 1 from omg_private.system_notice_templates where event_key='translation_warning');
insert into omg_private.system_notice_templates(event_key,title,body)
select 'translation_full','이번 달 번역 제공량 소진','{사업장명}의 기본 번역 제공량 {번역제공량}자를 모두 사용했습니다. 다음 달에 다시 제공됩니다. 계속 번역하려면 온라인 관리 > 기본정보에 개인 Google 번역 API 키를 등록해주세요. 개인 키 비용은 해당 Google 계정에 청구됩니다.' where not exists(select 1 from omg_private.system_notice_templates where event_key='translation_full');
CREATE OR REPLACE FUNCTION public.platform_system_notices(p_action text DEFAULT 'list'::text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare tid uuid;t omg_private.system_notice_templates%rowtype;prop uuid;n int:=0;value text;placeholder text;send_token text:=gen_random_uuid()::text;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='save' then
  if p_data->>'event_key' not in('first_login','storage_warning','storage_full','trial_expiring','trial_expired','subscription_expiring','subscription_expired','service_updated','manual','translation_warning','translation_full') then raise exception '알림 이벤트를 확인해주세요.';end if;
  value:=p_data->>'body';
  foreach placeholder in array array['사업장명','체험기간','제공용량','사용용량','종료일','남은일수','요금제','문의처','번역제공량','번역사용량'] loop value:=replace(value,'{'||placeholder||'}','');end loop;
  if value ~ '\\{[^{}]+\\}' then raise exception '지원하지 않는 치환 문구입니다. 화면의 자동입력 항목을 사용해주세요.';end if;
  tid:=nullif(p_data->>'id','')::uuid;
  if tid is null then insert into omg_private.system_notice_templates(event_key,title,body,enabled) values(p_data->>'event_key',btrim(p_data->>'title'),btrim(p_data->>'body'),coalesce((p_data->>'enabled')::boolean,true)) returning id into tid;
  else update omg_private.system_notice_templates set event_key=p_data->>'event_key',title=btrim(p_data->>'title'),body=btrim(p_data->>'body'),enabled=coalesce((p_data->>'enabled')::boolean,true),updated_at=now() where id=tid;
  if not found then raise exception '공지를 찾을 수 없습니다.';end if;end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'system_template_saved',jsonb_build_object('id',tid,'event_key',p_data->>'event_key'));
 elsif p_action='send' then
  if nullif(p_data->>'id','') is null then
   value:=btrim(coalesce(p_data->>'title',''));
   placeholder:=btrim(coalesce(p_data->>'body',''));
   if char_length(value) not between 1 and 80 then raise exception '공지 제목은 1~80자로 입력해주세요.';end if;
   if char_length(placeholder) not between 1 and 1400 then raise exception '공지 내용은 1~1400자로 입력해주세요.';end if;
   insert into omg_private.system_notice_templates(event_key,title,body,enabled,is_ad_hoc)
   values('manual',value,placeholder,true,true) returning id into tid;
   select * into t from omg_private.system_notice_templates where id=tid;
  else
   select * into t from omg_private.system_notice_templates where id=(p_data->>'id')::uuid and enabled;
   if not found then raise exception '활성 공지를 선택해주세요.';end if;
  end if;
  if jsonb_typeof(p_data->'property_ids') is distinct from 'array' or jsonb_array_length(p_data->'property_ids') not between 1 and 500 then raise exception '수신 사업장을 선택해주세요.';end if;
  for prop in select distinct x.value::uuid from jsonb_array_elements_text(p_data->'property_ids') as x(value) loop
   if not exists(select 1 from public.properties where id=prop) then raise exception '수신 사업장을 확인해주세요.';end if;
   n:=n+omg_private.emit_system_notice(prop,t.event_key,'manual:'||send_token||':'||prop::text,t.id);
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail)
  values(auth.uid(),'system_notice_sent',jsonb_build_object('template_id',t.id,'title',t.title,'count',n,'property_ids',p_data->'property_ids','ad_hoc',t.is_ad_hoc));
 elsif p_action='retry' then
  update omg_private.system_notice_deliveries set attempts=0,last_attempt_at=null where delivered_at is null and id=(p_data->>'id')::bigint;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'sent',n,
 'templates',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') from omg_private.system_notice_templates x where not x.is_ad_hoc),
 'deliveries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select d.id,d.event_key,d.created_at,d.attempts,d.delivered_at,d.message_id,p.name property_name,nt.title,
  case when d.delivered_at is not null then 'sent' when d.attempts>=10 then 'failed' else 'pending' end status,
  (select count(*) from public.property_message_recipients where message_id=d.message_id) recipient_count,
  (select count(*) from public.property_message_recipients where message_id=d.message_id and read_at is not null) read_count
  from omg_private.system_notice_deliveries d join public.properties p on p.id=d.property_id join omg_private.system_notice_templates nt on nt.id=d.template_id order by d.created_at desc limit 100)x));
end$function$
;
create or replace function omg_private.online_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;c omg_private.online_connections%rowtype;bid bigint;v_from date;v_to date;tz text;v_id uuid;d omg_private.online_outbox%rowtype;latest bigint;begin
 a:=omg_private.guest_actor(p_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 온라인 관리 권한이 없습니다.';end if;
 if p_data ? 'statuses' and (jsonb_typeof(p_data->'statuses')<>'array' or exists(select 1 from jsonb_array_elements_text(p_data->'statuses') x where x not in('new','confirmed','request','inquiry','cancelled','black','unknown'))) then raise exception '예약상태를 확인해주세요.';end if;
 insert into omg_private.online_connections(property_id) values(home) on conflict do nothing;
 select * into c from omg_private.online_connections where property_id=home;
 select timezone into tz from public.properties where id=home;
 if p_action='auth' then return jsonb_build_object('property_id',home,'actor',a->>'key','timezone',tz);end if;
 if p_action='reuse_connection' then
  if c.vault_id is not null then raise exception '이미 연결된 지점입니다.';end if;
  if not coalesce(omg_private.can_manage_shared_property(p_token,(p_data->>'source_property_id')::uuid,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,(p_data->>'source_property_id')::uuid,'messages'),false) then raise exception '기존 연결을 사용할 권한이 없습니다.';end if;
  update omg_private.online_connections target set vault_id=source.vault_id,properties=source.properties,connected_at=now() from omg_private.online_connections source where target.property_id=home and source.property_id=(p_data->>'source_property_id')::uuid and source.vault_id is not null;
  if not found then raise exception '사용 가능한 기존 연결이 없습니다.';end if;
  insert into omg_private.online_audit(property_id,action,actor,detail)values(home,'reuse_connection',a->>'key',jsonb_build_object('source_property_id',p_data->>'source_property_id'));
  return omg_private.online_owner(p_token,'settings',p_data);
 end if;
 if p_action='settings' then
  return jsonb_build_object('ok',true,'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p where omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages')),'connection_sources',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p join omg_private.online_connections co on co.property_id=p.id where p.id<>home and co.vault_id is not null and omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages')),'property_name',(select name from public.properties where id=home),'timezone',tz,'connected',c.vault_id is not null,'beds_property_id',c.beds_property_id,'beds_name',c.beds_name,'properties',c.properties,'property_id',home,'webhook_key',c.webhook_key,'ai_mode',c.ai_mode,'synced_at',c.synced_at,'webhook_at',c.webhook_at,'last_error',c.last_error,'translation_connected',c.translation_vault_id is not null,'message_period',(select period from omg_private.online_preferences where actor=a->>'key'),'data_count',(select jsonb_array_length(data) from omg_private.ai_settings where property_id=home));
 elsif p_action='save_settings' then
  if coalesce(p_data->>'ai_mode','off') not in('off','approval') then raise exception '현재는 승인 후 발송 모드만 지원합니다.';end if;
  bid:=nullif(p_data->>'beds_property_id','')::bigint;
  if c.vault_id is null then raise exception 'Beds24를 먼저 연결해주세요.';end if;
  if bid is null or not exists(select 1 from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid) then raise exception '연결된 Beds24 숙소를 선택해주세요.';end if;
  if c.beds_property_id is not null and c.beds_property_id<>bid then raise exception '다른 지점은 화면 상단의 지점 선택에서 변경해주세요. 현재 지점의 기존 숙소 연결은 유지됩니다.';end if;
  if exists(select 1 from omg_private.online_connections where beds_property_id=bid and property_id<>home) then raise exception '이미 다른 OMS 지점에 연결된 숙소입니다. 상단에서 해당 지점을 선택해주세요.';end if;
  update omg_private.online_connections set beds_property_id=bid,beds_name=(select x->>'name' from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid),ai_mode=p_data->>'ai_mode' where property_id=home;
  insert into omg_private.online_audit(property_id,action,actor,detail)values(home,'settings',a->>'key',jsonb_build_object('beds_property_id',bid,'ai_mode',p_data->>'ai_mode'));
 elsif p_action='bookings' then
  v_from:=(p_data->>'from')::date;v_to:=(p_data->>'to')::date;
  if v_from is null or v_to is null or v_to<v_from or v_to-v_from>92 then raise exception '조회 기간은 최대 93일입니다.';end if;
  return jsonb_build_object('ok',true,'synced_at',c.synced_at,'bookings',(select coalesce(jsonb_agg(to_jsonb(x) order by x.arrival,x.guest_name),'[]') from (select b.* from omg_private.online_bookings b where b.property_id=home and (not (p_data ? 'statuses') or coalesce(nullif(b.status,''),'unknown') in(select jsonb_array_elements_text(p_data->'statuses'))) and (not coalesce((p_data->>'active_only')::boolean,false) or coalesce(b.status,'') not in('cancelled','black','inquiry')) and case p_data->>'basis' when 'booked' then (b.booked_at at time zone tz)::date between v_from and v_to when 'staying' then b.arrival<=v_from and b.departure>v_from and coalesce(b.status,'') not in('cancelled','black','inquiry') else b.arrival between v_from and v_to end order by b.arrival,b.id limit 2000)x));
 elsif p_action in('inbox','unread') then
  v_from:=nullif(p_data->>'message_from','')::date;v_to:=nullif(p_data->>'message_to','')::date;
  if (v_from is null)<>(v_to is null) or v_to<v_from then raise exception '조회 기간을 확인해주세요.';end if;
  if coalesce(p_data->>'direction','all') not in('all','guest','host') then raise exception '수신·발신 구분을 확인해주세요.';end if;
  if p_action='unread' then
   return jsonb_build_object('ok',true,'unread',(select count(*) from omg_private.online_messages m where m.property_id=home and m.source='guest' and m.read_at is null and (v_from is null or m.sent_at >= (v_from::timestamp at time zone coalesce(tz,'Asia/Seoul')) and m.sent_at < ((v_to+1)::timestamp at time zone coalesce(tz,'Asia/Seoul')))));
  end if;
  return jsonb_build_object('ok',true,'synced_at',c.synced_at,'threads',(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('original_body',(select o.original_body from omg_private.online_outbox o where o.property_id=home and o.booking_id=x.booking_id and o.status='sent' and o.original_body is not null and x.source='host' and ((o.result->'remote'->>'id')=x.message_id::text or ((o.result->'remote'->>'id') is null and o.body=x.preview and abs(extract(epoch from o.updated_at-x.sent_at))<300)) order by o.updated_at desc limit 1)) order by x.sent_at desc,x.booking_id desc),'[]') from (
   select m.booking_id,max(m.sent_at) sent_at,count(*) filter(where m.source='guest' and m.read_at is null) unread,
    (array_agg(m.body order by m.sent_at desc,m.id desc))[1] preview,
    (array_agg(m.id order by m.sent_at desc,m.id desc))[1] message_id,
    (array_agg(m.source order by m.sent_at desc,m.id desc))[1] source,
    coalesce(b.guest_name,'예약 #'||m.booking_id) guest_name,b.room_name,b.arrival,b.departure,b.status,b.channel,
    (select count(*) from omg_private.online_outbox o where o.property_id=home and o.booking_id=m.booking_id and o.status='draft') drafts
   from omg_private.online_messages m left join omg_private.online_bookings b on b.property_id=m.property_id and b.id=m.booking_id
   where m.property_id=home and (coalesce(p_data->>'direction','all')='all' or m.source=p_data->>'direction')
    and (v_from is null or m.sent_at >= (v_from::timestamp at time zone coalesce(tz,'Asia/Seoul')) and m.sent_at < ((v_to+1)::timestamp at time zone coalesce(tz,'Asia/Seoul')))
    and (not (p_data ? 'statuses') or coalesce(nullif(b.status,''),'unknown') in(select jsonb_array_elements_text(p_data->'statuses')))
   group by m.booking_id,b.guest_name,b.room_name,b.arrival,b.departure,b.status,b.channel
   order by max(m.sent_at) desc,m.booking_id desc limit 300 offset greatest(0,least(15000,coalesce((p_data->>'offset')::int,0)))) x));
 elsif p_action='save_period' then
  if not coalesce(((p_data->'period'->>'days')::int between 1 and 3650 or (p_data->'period'->>'days')::int=0 and (p_data->'period'->>'from')::date <= (p_data->'period'->>'to')::date),false) then raise exception '기간을 확인해주세요.';end if;
  insert into omg_private.online_preferences(actor,period) values(a->>'key',jsonb_build_object('days',(p_data->'period'->>'days')::int,'from',p_data->'period'->>'from','to',p_data->'period'->>'to')) on conflict(actor) do update set period=excluded.period;
 elsif p_action='read_message' then
  update omg_private.online_messages set read_at=now() where property_id=home and id=(p_data->>'message_id')::bigint and source='guest' and read_at is null;
 elsif p_action='webhook_logs' then
  return jsonb_build_object('ok',true,'events',(select coalesce(jsonb_agg(to_jsonb(x) order by x.received_at desc),'[]') from(select id,booking_id,event_kind,received_at,status,processed_at,error from omg_private.online_webhook_receipts where property_id=home order by received_at desc limit 100)x));
 elsif p_action='save_translation' then
  if length(coalesce(p_data->>'key','')) not between 20 and 300 then raise exception 'Google Cloud Translation API 키를 확인해주세요.';end if;
  if c.translation_vault_id is null then
   v_id:=vault.create_secret(p_data->>'key','oms_translate_'||home,'Google Cloud Translation Basic');
   update omg_private.online_connections set translation_vault_id=v_id where property_id=home;
  else perform vault.update_secret(c.translation_vault_id,p_data->>'key');end if;
 elsif p_action in('thread','peek_thread') then
  bid:=(p_data->>'booking_id')::bigint;
  update omg_private.online_messages set read_at=now() where property_id=home and booking_id=bid and read_at is null and p_action='thread';
  return jsonb_build_object('ok',true,'booking',(select to_jsonb(b) from omg_private.online_bookings b where b.property_id=home and b.id=bid),'messages',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sent_at,x.id),'[]') from(select id,source,body,sent_at,attachment_name,(select o.original_body from omg_private.online_outbox o where o.property_id=home and o.booking_id=bid and o.status='sent' and o.original_body is not null and source='host' and ((o.result->'remote'->>'id')=online_messages.id::text or ((o.result->'remote'->>'id') is null and o.body=online_messages.body and abs(extract(epoch from o.updated_at-online_messages.sent_at))<300)) order by o.updated_at desc limit 1) original_body from omg_private.online_messages where property_id=home and booking_id=bid order by sent_at desc,id desc limit 500)x),'outbox',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from(select ob.*,(select display_name from public.owners where 'owner:'||id=ob.approved_by) approved_name from omg_private.online_outbox ob where property_id=home and booking_id=bid order by created_at desc limit 50)x));
 elsif p_action='logs' then
  return jsonb_build_object('ok',true,'logs',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select ob.*,(select display_name from public.owners where 'owner:'||id=ob.approved_by) approved_name from omg_private.online_outbox ob where property_id=home order by created_at desc limit 200)x),'events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select action,actor,detail,created_at from omg_private.online_audit where property_id=home order by created_at desc limit 50)x));
 elsif p_action='prepare_send' then
  bid:=(p_data->>'booking_id')::bigint;v_id:=(p_data->>'id')::uuid;
  if c.beds_property_id is null or not exists(select 1 from omg_private.online_bookings where property_id=home and id=bid) then raise exception '예약정보를 먼저 새로고침해주세요.';end if;
  if length(btrim(coalesce(p_data->>'body',''))) not between 1 and 4000 then raise exception '메시지는 1~4,000자로 입력해주세요.';end if;
  if p_data->>'translation_id' is not null and not exists(select 1 from omg_private.translation_jobs tj where tj.id=(p_data->>'translation_id')::uuid and tj.property_id=home and tj.booking_id=bid and tj.direction='outgoing' and tj.status='done' and tj.translated=btrim(p_data->>'body')) then raise exception '번역 미리보기를 다시 만들어주세요.';end if;
  perform pg_advisory_xact_lock(hashtextextended(home::text||':'||bid,909));
  select * into d from omg_private.online_outbox where id=v_id for update;
  if found then
   if d.property_id<>home or d.booking_id<>bid then raise exception '접근할 수 없는 발송 건입니다.';end if;
   if d.status<>'draft' then return jsonb_build_object('ok',true,'skip',true,'status',d.status);end if;
   select id into latest from omg_private.online_messages where property_id=home and booking_id=bid order by sent_at desc,id desc limit 1;
   if d.based_on is distinct from latest or exists(select 1 from omg_private.online_outbox other where other.property_id=home and other.booking_id=bid and other.id<>d.id and other.status in('sending','sent','uncertain') and other.created_at>=d.created_at) then update omg_private.online_outbox set status='stale',updated_at=now(),error='새 메시지가 도착해 초안을 다시 확인해야 합니다.' where id=v_id;return jsonb_build_object('ok',true,'skip',true,'status','stale');end if;
   update omg_private.online_outbox set status='sending',body=btrim(p_data->>'body'),approved_by=a->>'key',updated_at=now() where id=v_id;
  else
   insert into omg_private.online_outbox(id,property_id,booking_id,body,kind,status,actor,approved_by)values(v_id,home,bid,btrim(p_data->>'body'),'manual','sending',a->>'key',a->>'key');
  end if;
  if p_data->>'translation_id' is not null then
   update omg_private.online_outbox o set original_body=tj.body,translation_id=tj.id,target_language=tj.target from omg_private.translation_jobs tj where o.id=v_id and tj.id=(p_data->>'translation_id')::uuid;
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
 elsif p_action='reject' then
  update omg_private.online_outbox set status='rejected',approved_by=a->>'key',updated_at=now() where id=(p_data->>'id')::uuid and property_id=home and status='draft';
 else raise exception '지원하지 않는 요청입니다.';
 end if;
 return jsonb_build_object('ok',true);
end$$;

create or replace function public.owner_message_storage(p_access_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.owner_sessions%rowtype;v jsonb;begin
 select os.* into s from public.owner_sessions os join public.owners o on o.id=os.owner_id where os.login_token_hash=omg_private.token_hash(p_access_token) and os.token_expires_at>clock_timestamp() and o.active;
 if not found then raise exception '관리자 로그인이 만료되었습니다.';end if;
 v:=omg_private.data_management(null,'owner:'||s.owner_id,s.property_id,p_action,p_data);
 if p_action='usage' then v:=v||jsonb_build_object('properties',(select coalesce(jsonb_agg(x||jsonb_build_object('translation',omg_private.translation_summary((x->>'property_id')::uuid))),'[]') from jsonb_array_elements(v->'properties')x));end if;
 return v;
end$$;
commit;
