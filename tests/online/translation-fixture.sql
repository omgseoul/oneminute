create table public.account_properties(user_id uuid,property_id uuid);
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
create table omg_private.system_notice_templates(
 id uuid primary key default gen_random_uuid(),event_key text not null check(event_key in('first_login','storage_warning','storage_full','trial_expiring','trial_expired','subscription_expiring','subscription_expired','service_updated','manual')),
 title text not null check(char_length(btrim(title)) between 1 and 80),body text not null check(char_length(btrim(body)) between 1 and 1400),
 enabled boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table omg_private.system_notice_deliveries(
 id bigint generated always as identity primary key,property_id uuid not null references public.properties(id) on delete cascade,
 template_id uuid not null references omg_private.system_notice_templates(id),event_key text not null,event_instance text not null,
 message_id uuid references public.property_messages(id) on delete set null deferrable initially deferred,
 created_at timestamptz not null default now(),request_id bigint,attempts int not null default 0,last_attempt_at timestamptz,delivered_at timestamptz,
 unique(property_id,template_id,event_instance));

alter table omg_private.system_notice_templates add is_ad_hoc boolean default false;
alter table omg_private.service_plans add employee_limit int default 10,add room_limit int default 10;
create schema auth;create function auth.uid() returns uuid language sql as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function omg_private.is_platform_administrator(p uuid)returns boolean language sql as $$select exists(select 1 from public.platform_administrators where user_id=p)$$;
create function omg_private.property_usage_bytes(uuid)returns bigint language sql as $$select 0::bigint$$;
create function omg_private.service_bytes(bigint)returns text language sql as $$select $1::text$$;
create table omg_private.trial_codes(property_id uuid,trial_days int,code text);
create table public.platform_audit_logs(operator_user_id uuid,property_id uuid,action text,detail jsonb);
create function public.get_platform_dashboard()returns jsonb language sql as $$select jsonb_build_object('ok',true,'properties','[]'::jsonb)$$;
CREATE OR REPLACE FUNCTION public.get_property_service(p_access_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor jsonb;prop uuid;manage boolean:=false;s jsonb;plans jsonb;
begin if p_access_token is not null then actor:=omg_private.guest_actor(p_access_token);prop:=(actor->>'property_id')::uuid;manage:=actor->>'kind'='owner';
 else select property_id into prop from public.account_properties where user_id=auth.uid();manage:=prop is not null;end if;
 if prop is null then return jsonb_build_object('ok',false,'message','로그인이 필요합니다.');end if;
 perform 1 from public.properties where id=prop for update;
 s:=omg_private.property_service_state(prop);
 select jsonb_agg(to_jsonb(x) order by code) into plans from omg_private.service_plans x;
 return jsonb_build_object('ok',true,'service',s,'can_manage',manage,'plans',case when manage then plans else '[]'::jsonb end,'payment_connected',false);
end$function$
;
CREATE OR REPLACE FUNCTION omg_private.emit_system_notice(prop uuid, event text, instance text, only_template uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t omg_private.system_notice_templates%rowtype;s jsonb;mid uuid;message text;n int:=0;
begin
 if not exists(select 1 from public.owners where property_id=prop and active) then return 0;end if;
 s:=omg_private.property_service_state(prop);
 for t in select * from omg_private.system_notice_templates where enabled and event_key=event and (only_template is null or id=only_template) loop
  mid:=gen_random_uuid();
  insert into omg_private.system_notice_deliveries(property_id,template_id,event_key,event_instance,message_id) values(prop,t.id,event,instance,mid) on conflict do nothing;
  if not found then continue;end if;
  message:=t.title||E'\n'||case when t.is_ad_hoc then t.body else omg_private.render_system_notice(t.body,prop,s) end;
  insert into public.property_messages(id,business_id,property_id,sender_type,message,priority,message_type,source)
  select mid,business_id,id,'system',left(message,2000),'normal','general','platform_system' from public.properties where id=prop;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select mid,'owner:'||id,'owner',id from public.owners where property_id=prop and active;
  n:=n+1;
 end loop;
 return n;
end$function$
;
