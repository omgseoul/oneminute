create table if not exists omg_private.service_policy(
 id boolean primary key default true check(id),trial_days integer not null default 30 check(trial_days between 1 and 365),
 reminder_days integer not null default 7 check(reminder_days between 0 and 365),grace_days integer not null default 3 check(grace_days between 0 and 90),
 storage_limit_bytes bigint not null default 2147483648 check(storage_limit_bytes between 1048576 and 1099511627776),
 storage_warning_bytes bigint not null default 1073741824 check(storage_warning_bytes between 1 and 1099511627776),
 end_action text not null default 'notice' check(end_action in('notice','restrict_writes')),
 storage_action text not null default 'warn' check(storage_action in('warn','block_photos')),
 support_contact text not null default '' check(char_length(support_contact)<=200),updated_at timestamptz not null default now(),
 check(storage_warning_bytes<=storage_limit_bytes));
insert into omg_private.service_policy(id) values(true) on conflict do nothing;
alter table omg_private.service_policy enable row level security;
revoke all on omg_private.service_policy from public,anon,authenticated;
create table if not exists omg_private.service_plans(
 code text primary key check(code in('basic','pro')),name text not null,monthly_price integer check(monthly_price between 0 and 10000000),
 storage_limit_bytes bigint not null check(storage_limit_bytes between 1048576 and 1099511627776));
insert into omg_private.service_plans values('basic','기본',null,2147483648),('pro','프로',null,5368709120) on conflict do nothing;
alter table omg_private.service_plans enable row level security;revoke all on omg_private.service_plans from public,anon,authenticated;
alter table public.properties add column if not exists service_plan text not null default 'basic',
 add column if not exists subscription_ends_at timestamptz,add column if not exists billing_exempt boolean not null default false,
 add column if not exists service_storage_limit bigint,add column if not exists service_storage_warning bigint;
update public.properties p set billing_exempt=true where exists(select 1 from public.account_properties a join public.platform_administrators x on x.user_id=a.user_id where a.property_id=p.id);
update public.properties set trial_ends_at=created_at+interval '30 days' where service_status='trial' and trial_ends_at is null;
create table if not exists omg_private.service_notices(
 property_id uuid primary key references public.properties(id) on delete cascade,state jsonb not null,checked_at timestamptz not null default now());
alter table omg_private.service_notices enable row level security;revoke all on omg_private.service_notices from public,anon,authenticated;
create or replace function omg_private.initialize_service_trial() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.service_status='trial' and new.trial_ends_at is null then
 select clock_timestamp()+make_interval(days=>trial_days) into new.trial_ends_at from omg_private.service_policy where id;
 end if;return new;end$$;
revoke all on function omg_private.initialize_service_trial() from public,anon,authenticated;
create trigger initialize_service_trial before insert on public.properties for each row execute function omg_private.initialize_service_trial();
create or replace function omg_private.property_usage_bytes(prop uuid) returns bigint language sql volatile security definer set search_path='' as $$
 select (select coalesce(sum(octet_length(payload::text)),0) from public.work_reports where property_id=prop)
 +(select coalesce(sum(octet_length(message)),0) from public.property_messages where property_id=prop)
 +(select coalesce(sum(octet_length(m.body)),0) from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where r.property_id=prop)
 +(select coalesce(sum(omg_private.guest_asset_bytes(a.object_path)),0) from public.guest_support_assets a where a.property_id=prop)
 +(select coalesce(sum(coalesce((o.metadata->>'size')::bigint,0)),0) from storage.objects o join public.employees e on e.id=omg_private.document_employee(o.name) where o.bucket_id='employee-documents' and e.property_id=prop)
 +(select coalesce(sum(octet_length(coalesce(c.photo_data_url,''))+octet_length(coalesce(c.note,''))),0) from public.mission_completions c join public.missions m on m.id=c.mission_id where m.property_id=prop)
 +(select coalesce(sum(octet_length(coalesce(m.description_photo,''))),0) from public.missions m where m.property_id=prop)
 +(select coalesce(sum(octet_length(e.report_config::text)),0) from public.employees e where e.property_id=prop);
$$;
revoke all on function omg_private.property_usage_bytes(uuid) from public,anon,authenticated;
create or replace function omg_private.property_service_state(prop uuid) returns jsonb language plpgsql volatile security definer set search_path='' as $$
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
 'storage_action',c.storage_action,'support_contact',c.support_contact,'usage_estimated',true,'checked_at',now());
end$$;
revoke all on function omg_private.property_service_state(uuid) from public,anon,authenticated;
create or replace function public.get_property_service(p_access_token uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor jsonb;prop uuid;manage boolean:=false;s jsonb;plans jsonb;
begin if p_access_token is not null then actor:=omg_private.guest_actor(p_access_token);prop:=(actor->>'property_id')::uuid;manage:=actor->>'kind'='owner';
 else select property_id into prop from public.account_properties where user_id=auth.uid();manage:=prop is not null;end if;
 if prop is null then return jsonb_build_object('ok',false,'message','로그인이 필요합니다.');end if;
 perform 1 from public.properties where id=prop for update;
 s:=omg_private.property_service_state(prop);
 select jsonb_agg(to_jsonb(x) order by code) into plans from omg_private.service_plans x;
 return jsonb_build_object('ok',true,'service',s,'can_manage',manage,'plans',case when manage then plans else '[]'::jsonb end,'payment_connected',false);
end$$;
revoke all on function public.get_property_service(uuid) from public;grant execute on function public.get_property_service(uuid) to anon,authenticated;
create or replace function public.platform_operations(p_action text default 'get',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare prop uuid;c omg_private.service_policy%rowtype;old jsonb;result jsonb;plan jsonb;name text;status text;
begin if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'code','platform_admin_required','message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='policy' then
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 update omg_private.service_policy set trial_days=(p_data->>'trial_days')::int,reminder_days=(p_data->>'reminder_days')::int,grace_days=(p_data->>'grace_days')::int,
 storage_limit_bytes=(p_data->>'storage_limit_bytes')::bigint,storage_warning_bytes=(p_data->>'storage_warning_bytes')::bigint,
 end_action=p_data->>'end_action',storage_action=p_data->>'storage_action',support_contact=btrim(coalesce(p_data->>'support_contact','')),updated_at=now() where id;
 for plan in select * from jsonb_array_elements(p_data->'plans') loop
 update omg_private.service_plans set name=left(btrim(plan->>'name'),40),monthly_price=nullif(plan->>'monthly_price','')::integer,storage_limit_bytes=(plan->>'storage_limit_bytes')::bigint where code=plan->>'code';
 if not found or btrim(plan->>'name')='' then raise exception '요금제 이름과 용량을 확인해주세요.';end if;end loop;
 insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'service_policy_updated',jsonb_build_object('before',old,'after',p_data));
 elsif p_action='customer' then
 prop:=(p_data->>'property_id')::uuid;select service_status into status from public.properties where id=prop;
 if status is null then return jsonb_build_object('ok',false,'message','고객을 찾을 수 없습니다.');end if;
 if p_data->>'service_plan' not in('basic','pro') then raise exception '요금제를 확인해주세요.';end if;
 select to_jsonb(p) into old from public.properties p where id=prop;
 result:=public.update_platform_property(prop,coalesce(p_data->>'service_status',status),coalesce(p_data->>'operator_note',''));if not(result->>'ok')::boolean then return result;end if;
 update public.properties set service_plan=p_data->>'service_plan',billing_exempt=coalesce((p_data->>'billing_exempt')::boolean,false),
 trial_ends_at=nullif(p_data->>'trial_ends_at','')::timestamptz,subscription_ends_at=nullif(p_data->>'subscription_ends_at','')::timestamptz,
 service_storage_limit=nullif(p_data->>'storage_limit_bytes','')::bigint,service_storage_warning=nullif(p_data->>'storage_warning_bytes','')::bigint where id=prop;
 if exists(select 1 from public.properties where id=prop and (service_storage_limit<1048576 or service_storage_warning<1 or service_storage_warning>service_storage_limit)) then raise exception '고객별 용량과 경고 기준을 확인해주세요.';end if;
 insert into public.platform_audit_logs(operator_user_id,property_id,action,detail) values(auth.uid(),prop,'customer_service_updated',jsonb_build_object('before',jsonb_build_object('plan',old->'service_plan','trial_ends_at',old->'trial_ends_at','subscription_ends_at',old->'subscription_ends_at','billing_exempt',old->'billing_exempt'),'after',p_data));
 elsif p_action not in('get','usage') then raise exception '지원하지 않는 요청입니다.';end if;
 result:=public.get_platform_dashboard();
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 perform omg_private.refresh_service_notices();
 select coalesce(jsonb_agg((x.value)||jsonb_build_object('service_plan',p.service_plan,'billing_exempt',p.billing_exempt,'subscription_ends_at',p.subscription_ends_at,'storage_limit_override',p.service_storage_limit,'storage_warning_override',p.service_storage_warning,'service',coalesce(n.state,omg_private.property_service_state(p.id))) order by p.management_number),'[]'::jsonb) into plan
 from jsonb_array_elements(result->'properties')x(value) join public.properties p on p.id=(x.value->>'property_id')::uuid left join omg_private.service_notices n on n.property_id=p.id;
 return result||jsonb_build_object('properties',plan,'policy',old,'plans',(select jsonb_agg(to_jsonb(x) order by code) from omg_private.service_plans x),'last_checked_at',(select max(checked_at) from omg_private.service_notices),'payment_connected',false);
end$$;
revoke all on function public.platform_operations(text,jsonb) from public,anon;grant execute on function public.platform_operations(text,jsonb) to authenticated;
create or replace function omg_private.refresh_service_notices() returns void language plpgsql security definer set search_path='' as $$
begin insert into omg_private.service_notices(property_id,state,checked_at) select id,omg_private.property_service_state(id),now() from public.properties
 on conflict(property_id) do update set state=excluded.state,checked_at=excluded.checked_at;end$$;
revoke all on function omg_private.refresh_service_notices() from public,anon,authenticated;
select cron.schedule('omg-service-policy-check','0 * * * *','select omg_private.refresh_service_notices()');
create or replace function omg_private.guard_service_write() returns trigger language plpgsql security definer set search_path='' as $$
declare prop uuid;s jsonb;delta bigint:=0;has_photo boolean:=false;before_bytes bigint:=0;
begin
 if tg_table_schema='storage' then
 if new.bucket_id='guest-support' then select property_id into prop from public.guest_support_assets where object_path=new.name;
 elsif new.bucket_id='employee-documents' then select property_id into prop from public.employees where id=omg_private.document_employee(new.name);end if;
 if prop is null then return new;end if;has_photo:=true;delta:=coalesce((new.metadata->>'size')::bigint,0);if tg_op='UPDATE' then delta:=delta-coalesce((old.metadata->>'size')::bigint,0);end if;
 elsif tg_table_name='mission_completions' then select property_id into prop from public.missions where id=new.mission_id;
 elsif tg_table_name='guest_chat_messages' then select property_id into prop from public.guest_chat_rooms where id=new.room_id;
 else prop:=new.property_id;end if;
 perform 1 from public.properties where id=prop for update;
 s:=omg_private.property_service_state(prop);
 if coalesce((s->>'restricted')::boolean,false) then raise exception '이용 기간이 종료되었습니다. 관리자에게 구독 연장을 요청해주세요.';end if;
 if tg_table_name='mission_completions' then has_photo:=coalesce(new.photo_data_url,'')<>'';delta:=octet_length(coalesce(new.photo_data_url,''));if tg_op='UPDATE' then delta:=delta-octet_length(coalesce(old.photo_data_url,''));end if;
 elsif tg_table_name='work_reports' then has_photo:=new.payload::text like '%data:image/%';delta:=octet_length(new.payload::text);if tg_op='UPDATE' then delta:=delta-octet_length(old.payload::text);end if;
 elsif tg_table_name='property_messages' then has_photo:=new.message like '%data:image/%';delta:=octet_length(new.message);if tg_op='UPDATE' then delta:=delta-octet_length(old.message);end if;end if;
 if has_photo and delta>0 and not(s->>'exempt')::boolean and s->>'storage_action'='block_photos' and (s->>'used_bytes')::bigint+delta>(s->>'limit_bytes')::bigint then raise exception '저장 용량을 초과했습니다. 관리자에게 용량 추가를 요청해주세요.';end if;
 return new;
end$$;
revoke all on function omg_private.guard_service_write() from public,anon,authenticated;
create trigger service_guard before insert or update on public.work_reports for each row execute function omg_private.guard_service_write();
create trigger service_guard before insert or update on public.property_messages for each row execute function omg_private.guard_service_write();
create trigger service_guard before insert or update on public.calendar_events for each row execute function omg_private.guard_service_write();
create trigger service_guard before insert or update on public.missions for each row execute function omg_private.guard_service_write();
create trigger service_guard before insert or update on public.guest_chat_messages for each row execute function omg_private.guard_service_write();
create trigger service_guard before insert or update on storage.objects for each row execute function omg_private.guard_service_write();

create trigger service_guard before insert or update on public.mission_completions for each row execute function omg_private.guard_service_write();
