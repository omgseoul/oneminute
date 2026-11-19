-- Monthly allowance is derived from the usage ledger, not a separately funded wallet.
-- Keep the original reserve/settlement paths, but make all legacy balance writes
-- normalize to allowance - actual usage. ai_usage_month remains the single budget
-- gate for every AI feature, including in-flight reservations.
alter table omg_private.ai_wallets add column if not exists allowance_month date;
create or replace function omg_private.ai_normalize_wallet() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 new.allowance_month:=omg_private.ai_month();
 new.balance_micro:=greatest(0,new.monthly_limit_micro-coalesce((select used_micro from omg_private.ai_usage_month where property_id=new.property_id and month=new.allowance_month),0));
 return new;
end$$;
revoke all on function omg_private.ai_normalize_wallet() from public,anon,authenticated;
create trigger ai_monthly_wallet_normalize before insert or update on omg_private.ai_wallets for each row execute function omg_private.ai_normalize_wallet();

create or replace function omg_private.ai_sync_monthly_usage() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 -- A settlement after midnight updates its original period only. The wallet
 -- trigger always uses the current period, so it cannot debit/refund a new month.
 update omg_private.ai_wallets set updated_at=now() where property_id=new.property_id;
 return new;
end$$;
revoke all on function omg_private.ai_sync_monthly_usage() from public,anon,authenticated;
create trigger ai_monthly_usage_sync after insert or update on omg_private.ai_usage_month for each row execute function omg_private.ai_sync_monthly_usage();

create or replace function omg_private.ai_refresh_month(p_property uuid default null) returns void
language sql security definer set search_path='' as $$
 update omg_private.ai_wallets set updated_at=now()
 where (p_property is null or property_id=p_property) and allowance_month is distinct from omg_private.ai_month()
$$;
revoke all on function omg_private.ai_refresh_month(uuid) from public,anon,authenticated;
grant execute on function omg_private.ai_refresh_month(uuid) to service_role;

create or replace function omg_private.ai_summary(p_property uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('balance',greatest(0,coalesce(w.monthly_limit_micro,0)-coalesce(u.used_micro,0))/1000.0,
 'monthly_limit',coalesce(w.monthly_limit_micro,0)/1000.0,'used',coalesce(u.used_micro,0)/1000.0,
 'reserved',coalesce(u.reserved_micro,0)/1000.0,'enabled',coalesce(w.enabled,false),'responses',coalesce(u.responses,0),
 'month',omg_private.ai_month(),'credit_usd',0.001,'auto_refill',true,'rollover',false,
 'available',greatest(0,coalesce(w.monthly_limit_micro,0)-coalesce(u.used_micro+u.reserved_micro,0))/1000.0)
 from (select p_property id)x left join omg_private.ai_wallets w on w.property_id=x.id
 left join omg_private.ai_usage_month u on u.property_id=x.id and u.month=omg_private.ai_month()
$$;

-- Refresh under the existing per-property locks before a budget read. This also
-- covers the instant of month change if the cron runner has not fired yet.
-- Replace only exact budget-read anchors, preserving unrelated production logic.
do $$
declare item record;definition text;anchor text;replacement text;
begin
 for item in select * from (values
 ('ai_claim','select * into w from omg_private.ai_wallets where property_id=r.property_id for update;','r.property_id'),
 ('briefing_worker','select balance_micro,monthly_limit_micro into bal,cap from omg_private.ai_wallets where property_id=r.property_id and enabled for update;','r.property_id'),
 ('online_internal','select balance_micro into budget from omg_private.ai_wallets where property_id=p_property and enabled for update;','p_property'),
 ('online_arrival_control','select balance_micro into balance from omg_private.ai_wallets where property_id=prop and enabled for update;','prop')
 )v(name,anchor,property) loop
  select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='omg_private' and p.proname=item.name;
  -- Optional online arrivals function is not installed in minimal test databases.
  if definition is null and item.name='online_arrival_control' then continue;end if;
  if definition is null or position(item.anchor in definition)=0 then raise exception 'Missing monthly budget anchor: %',item.name;end if;
  definition:=replace(definition,'from omg_private.ai_jobs where property_id=r.property_id and status=''leased''','from omg_private.ai_jobs where property_id=r.property_id and status=''leased'' and period=omg_private.ai_month()');
  definition:=replace(definition,'from omg_private.ai_jobs where property_id=p_property and status=''leased''','from omg_private.ai_jobs where property_id=p_property and status=''leased'' and period=omg_private.ai_month()');
  definition:=replace(definition,'from omg_private.ai_jobs where property_id=prop and status=''leased''','from omg_private.ai_jobs where property_id=prop and status=''leased'' and period=omg_private.ai_month()');
  execute replace(definition,item.anchor,'perform omg_private.ai_refresh_month('||item.property||'); '||item.anchor);
 end loop;
end$$;

-- Preparsed SQL bodies retain SECURITY INVOKER and the private function's token
-- and property authorization, without granting access to the whole private schema.
create or replace function public.employee_duty_roles(p_access_token uuid,p_property_id uuid,p_action text default 'get',p_data jsonb default '{}') returns jsonb language sql security invoker set search_path=''
begin atomic
 select omg_private.employee_duty_roles(p_access_token,p_property_id,p_action,p_data);
end;
create or replace function public.bot_briefing_settings(p_access_token uuid,p_property_id uuid,p_action text default 'get',p_data jsonb default '{}') returns jsonb language sql security invoker set search_path=''
begin atomic
 select omg_private.briefing_owner(p_access_token,p_property_id,p_action,p_data);
end;

-- Initialize existing properties from this month's actual usage, preserving logs.
update omg_private.ai_wallets set updated_at=now();
-- UTC 15:00 is 00:00 KST; daily idempotent check only changes a new month.
select cron.schedule('oms-ai-monthly-allowance','0 15 * * *','select omg_private.ai_refresh_month()');

CREATE OR REPLACE FUNCTION omg_private.ai_platform(p_user uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare secretid uuid;prop uuid;delta bigint;cap bigint;request uuid;old omg_private.ai_credit_log%rowtype;begin
 if not exists(select 1 from public.platform_administrators where user_id=p_user) then raise exception '운영센터 권한이 필요합니다.';end if;
 if p_action='connect' then
  if (coalesce(p_data->>'key','') !~ '^sk-[A-Za-z0-9_-]+$' or length(p_data->>'key') not between 23 and 503) then raise exception 'API 키를 확인해주세요.';end if;
  select vault_id into secretid from omg_private.ai_provider where singleton for update;
  if secretid is null then select vault.create_secret(p_data->>'key','oms_guest_ai_api_key','OMS guest AI provider') into secretid;else perform vault.update_secret(secretid,p_data->>'key');end if;
  update omg_private.ai_provider set vault_id=secretid,key_suffix=right(p_data->>'key',4),updated_at=now() where singleton;
 elsif p_action='provider' then update omg_private.ai_provider set enabled=coalesce((p_data->>'enabled')::boolean,false),updated_at=now() where singleton;
 elsif p_action='wallet' then
  prop:=(p_data->>'property_id')::uuid;request:=(p_data->>'request_id')::uuid;delta:=round((p_data->>'delta')::numeric*1000);cap:=round((p_data->>'monthly_limit')::numeric*1000);
  if coalesce(delta,0)<>0 then raise exception '월 자동충전 한도를 변경해주세요. 별도 잔액 추가·차감은 사용하지 않습니다.';end if;
  delta:=0;
  if request is null or delta is null or abs(delta)>100000000000 or cap is null or cap not between 0 and 100000000000 then raise exception '크레딧과 월 한도를 확인해주세요.';end if;
  perform pg_advisory_xact_lock(hashtextextended(request::text,91));select * into old from omg_private.ai_credit_log where request_id=request;
  if found then if old.property_id<>prop or old.user_id<>p_user or old.delta_micro<>delta then raise exception '이미 처리한 요청입니다.';end if;
  else
   insert into omg_private.ai_wallets(property_id) values(prop) on conflict do nothing;
   perform 1 from omg_private.ai_wallets where property_id=prop for update;

   update omg_private.ai_wallets set balance_micro=balance_micro+delta,monthly_limit_micro=cap,enabled=coalesce((p_data->>'enabled')::boolean,false),updated_at=now() where property_id=prop;
   insert into omg_private.ai_credit_log(request_id,property_id,user_id,delta_micro,note)values(request,prop,p_user,delta,left('월 자동충전 한도 '||(cap/1000.0)::text||' 크레딧 · '||coalesce(p_data->>'note',''),300));
  end if;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'provider',(select jsonb_build_object('ready',vault_id is not null,'suffix',key_suffix,'enabled',enabled,'model','gpt-6-luna') from omg_private.ai_provider),'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'number',p.management_number,'usage',omg_private.ai_summary(p.id),'ai_enabled',coalesce(s.enabled,false)) order by p.name),'[]') from public.properties p left join omg_private.ai_settings s on s.property_id=p.id),'adjustments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select l.created_at,p.name,l.delta_micro/1000.0 credits,l.note from omg_private.ai_credit_log l join public.properties p on p.id=l.property_id order by l.created_at desc limit 60)x));
end$function$
