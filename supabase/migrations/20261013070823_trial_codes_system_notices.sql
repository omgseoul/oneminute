-- One-time trial invitations and operator-controlled service messages.
alter table omg_private.service_policy add column trial_code_required boolean not null default false,
 add column trial_code_required_from timestamptz;
alter table omg_private.service_plans drop constraint if exists service_plans_code_check;
alter table omg_private.service_plans add constraint service_plans_code_check check(code ~ '^[a-z][a-z0-9_-]{1,39}$');
alter table public.account_properties add column first_admin_login_at timestamptz;

create table omg_private.trial_codes(
 id uuid primary key default gen_random_uuid(),code text not null unique check(code ~ '^[A-Z0-9]{8}$'),
 trial_days int not null check(trial_days between 1 and 365),storage_limit_bytes bigint not null check(storage_limit_bytes between 1048576 and 1099511627776),
 expires_at timestamptz,note text not null default '' check(char_length(note)<=300),
 created_by uuid references auth.users(id) on delete set null,created_at timestamptz not null default now(),
 revoked_at timestamptz,used_at timestamptz,used_by uuid unique references auth.users(id) on delete set null,
 used_email text,registration_name text,registration_property_name text,property_id uuid references public.properties(id) on delete set null,
 check(used_by is null or used_at is not null));
create index trial_codes_created on omg_private.trial_codes(created_at desc);
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
create index system_notice_pending on omg_private.system_notice_deliveries(last_attempt_at) where delivered_at is null;
alter table omg_private.trial_codes enable row level security;
alter table omg_private.system_notice_templates enable row level security;
alter table omg_private.system_notice_deliveries enable row level security;
revoke all on omg_private.trial_codes,omg_private.system_notice_templates,omg_private.system_notice_deliveries from public,anon,authenticated;
create policy no_client_access on omg_private.trial_codes for all to anon,authenticated using(false) with check(false);
create policy no_client_access on omg_private.system_notice_templates for all to anon,authenticated using(false) with check(false);
create policy no_client_access on omg_private.system_notice_deliveries for all to anon,authenticated using(false) with check(false);

create function omg_private.normalize_trial_code(value text) returns text language sql immutable set search_path='' as $$
 select upper(regexp_replace(coalesce(value,''),'[[:space:]-]','','g'));
$$;
revoke all on function omg_private.normalize_trial_code(text) from public,anon,authenticated;
create function public.check_trial_code(p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.trial_codes%rowtype;
begin
 if omg_private.normalize_trial_code(p_code) !~ '^[A-Z0-9]{8}$' then return jsonb_build_object('ok',false,'message','체험코드를 확인해주세요.');end if;
 select * into c from omg_private.trial_codes where code=omg_private.normalize_trial_code(p_code) and used_at is null and revoked_at is null and (expires_at is null or expires_at>now());
 if not found then return jsonb_build_object('ok',false,'message','사용 가능한 체험코드가 아닙니다. 코드를 확인하거나 운영자에게 문의해주세요.');end if;
 return jsonb_build_object('ok',true,'trial_days',c.trial_days,'storage_limit_bytes',c.storage_limit_bytes);
end$$;
revoke all on function public.check_trial_code(text) from public;
grant execute on function public.check_trial_code(text) to anon,authenticated;

create function omg_private.redeem_signup_trial_code() returns trigger language plpgsql security definer set search_path='' as $$
declare value text;c omg_private.trial_codes%rowtype;required boolean;
begin
 value:=omg_private.normalize_trial_code(new.raw_user_meta_data->>'trial_code');
 select trial_code_required into required from omg_private.service_policy where id;
 if value='' and not required then return new;end if;
 select * into c from omg_private.trial_codes where code=value for update;
 if not found or c.used_at is not null or c.revoked_at is not null or (c.expires_at is not null and c.expires_at<=clock_timestamp()) then
  raise exception '사용 가능한 체험코드가 아닙니다.';
 end if;
 update omg_private.trial_codes set used_at=clock_timestamp(),used_by=new.id,used_email=new.email,
 registration_name=left(btrim(coalesce(new.raw_user_meta_data->>'name','관리자')),50),
 registration_property_name=left(btrim(coalesce(new.raw_user_meta_data->>'property_name','새 사업장')),80) where id=c.id;
 -- Trial entitlements come only from this server-owned record, never editable JWT metadata.
 return new;
end$$;
revoke all on function omg_private.redeem_signup_trial_code() from public,anon,authenticated;
create trigger oms_redeem_signup_trial_code after insert on auth.users for each row execute function omg_private.redeem_signup_trial_code();

insert into omg_private.system_notice_templates(event_key,title,body) values
 ('first_login','가입을 축하드립니다','{사업장명} 관리자님, 가입을 축하드립니다. {체험기간}일 동안 체험이 가능하며, 저장 용량은 {제공용량}으로 제한됩니다. 체험 종료일은 {종료일}입니다.'),
 ('storage_warning','저장공간이 부족해지고 있습니다','저장공간 {사용용량} / {제공용량}을 사용 중입니다. 필요 없는 기존 데이터를 정리해주세요. {문의처}'),
 ('storage_full','저장공간이 다 찼습니다','저장공간이 다 찼습니다. 기존 데이터를 정리해주세요. 사용량: {사용용량} / {제공용량}. {문의처}'),
 ('trial_expiring','체험 종료가 다가옵니다','체험 종료까지 {남은일수}일 남았습니다. 종료일은 {종료일}입니다. 이용을 계속하려면 문의해주세요. {문의처}'),
 ('trial_expired','체험 기간이 종료되었습니다','체험 기간이 종료되었습니다. 이용권 연장이 필요하면 문의해주세요. {문의처}'),
 ('subscription_expiring','이용권 종료가 다가옵니다','이용권 종료까지 {남은일수}일 남았습니다. 종료일은 {종료일}입니다. {문의처}'),
 ('subscription_expired','이용권 기간이 종료되었습니다','이용권 기간이 종료되었습니다. 연장이 필요하면 문의해주세요. {문의처}'),
 ('service_updated','이용 설정이 변경되었습니다','운영자가 이용 설정을 변경했습니다. 요금제: {요금제}, 제공 용량: {제공용량}, 종료일: {종료일}. {문의처}');

create function omg_private.service_bytes(value bigint) returns text language sql immutable set search_path='' as $$
 select case when value>=1073741824 then round(value::numeric/1073741824,2)::text||'GB' else round(value::numeric/1048576,1)::text||'MB' end;
$$;
create function omg_private.render_system_notice(value text,prop uuid,s jsonb) returns text language plpgsql security definer set search_path='' as $$
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
 return result;
end$$;
revoke all on function omg_private.service_bytes(bigint),omg_private.render_system_notice(text,uuid,jsonb) from public,anon,authenticated;

create function omg_private.emit_system_notice(prop uuid,event text,instance text,only_template uuid default null) returns int language plpgsql security definer set search_path='' as $$
declare t omg_private.system_notice_templates%rowtype;s jsonb;mid uuid;message text;n int:=0;
begin
 if not exists(select 1 from public.owners where property_id=prop and active) then return 0;end if;
 s:=omg_private.property_service_state(prop);
 for t in select * from omg_private.system_notice_templates where enabled and event_key=event and (only_template is null or id=only_template) loop
  mid:=gen_random_uuid();
  insert into omg_private.system_notice_deliveries(property_id,template_id,event_key,event_instance,message_id) values(prop,t.id,event,instance,mid) on conflict do nothing;
  if not found then continue;end if;
  message:='[시스템] '||t.title||E'\n'||omg_private.render_system_notice(t.body,prop,s);
  insert into public.property_messages(id,business_id,property_id,sender_type,message,priority,message_type,source)
  select mid,business_id,id,'system',left(message,2000),'normal','general','platform_system' from public.properties where id=prop;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select mid,'owner:'||id,'owner',id from public.owners where property_id=prop and active;
  n:=n+1;
 end loop;
 return n;
end$$;
revoke all on function omg_private.emit_system_notice(uuid,text,text,uuid) from public,anon,authenticated;

create function omg_private.dispatch_system_notices() returns int language plpgsql security definer set search_path='' as $$
declare d record;secret text;req bigint;n int:=0;
begin
 select decrypted_secret into secret from vault.decrypted_secrets where name='omg_guest_email_worker_secret' limit 1;
 if secret is null then return 0;end if;
 update omg_private.system_notice_deliveries d set delivered_at=now() from net._http_response r where r.id=d.request_id and d.delivered_at is null and r.status_code between 200 and 299 and case when pg_input_is_valid(r.content,'jsonb') then r.content::jsonb->>'ok'='true' else false end;
 for d in select * from omg_private.system_notice_deliveries where delivered_at is null and message_id is not null and attempts<10 and (last_attempt_at is null or last_attempt_at<now()-interval '2 minutes') order by created_at limit 50 for update skip locked loop
  req:=net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder',headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',secret),body:=jsonb_build_object('message_id',d.message_id));
  update omg_private.system_notice_deliveries set request_id=req,attempts=attempts+1,last_attempt_at=now() where id=d.id;n:=n+1;
 end loop;
 return n;
end$$;
revoke all on function omg_private.dispatch_system_notices() from public,anon,authenticated;

create or replace function omg_private.refresh_service_notices() returns void language plpgsql security definer set search_path='' as $$
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
  insert into omg_private.service_notices(property_id,state,checked_at) values(p.id,s,now()) on conflict(property_id) do update set state=excluded.state,checked_at=excluded.checked_at;
 end loop;
end$$;

create function public.platform_trial_codes(p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare n int;value text;days int;lim bigint;expiry timestamptz;items jsonb;c omg_private.trial_codes%rowtype;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='create' then
  n:=coalesce((p_data->>'count')::int,1);if n not between 1 and 100 then raise exception '한 번에 1~100개를 생성할 수 있습니다.';end if;
  select coalesce((p_data->>'trial_days')::int,trial_days),coalesce((p_data->>'storage_limit_bytes')::bigint,storage_limit_bytes) into days,lim from omg_private.service_policy where id;
  expiry:=nullif(p_data->>'expires_at','')::timestamptz;
  if expiry is not null and expiry<=now() then raise exception '코드 만료일은 미래로 설정해주세요.';end if;
  if btrim(coalesce(p_data->>'code',''))<>'' and n<>1 then raise exception '직접 지정한 코드는 한 개씩 생성해주세요.';end if;
  for i in 1..n loop
   value:=omg_private.normalize_trial_code(nullif(btrim(p_data->>'code'),''));
   if value='' then loop value:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));exit when not exists(select 1 from omg_private.trial_codes as existing_code where existing_code.code=value);end loop;elsif value !~ '^[A-Z0-9]{8}$' then raise exception '체험코드는 영문 또는 숫자 8자리로 입력해주세요.';end if;
   insert into omg_private.trial_codes(code,trial_days,storage_limit_bytes,expires_at,note,created_by) values(value,days,lim,expiry,btrim(coalesce(p_data->>'note','')),auth.uid());
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_codes_created',jsonb_build_object('count',n,'trial_days',days,'storage_limit_bytes',lim));
 elsif p_action='revoke' then
  update omg_private.trial_codes set revoked_at=now() where id=(p_data->>'id')::uuid and used_at is null and revoked_at is null;
  if not found then return jsonb_build_object('ok',false,'message','미사용 코드만 사용 중지할 수 있습니다.');end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_code_revoked',jsonb_build_object('id',p_data->>'id'));
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into items from(
  select tc.id,tc.code,tc.trial_days,tc.storage_limit_bytes,tc.expires_at,tc.note,tc.created_at,tc.used_at,tc.used_email,tc.registration_name,tc.registration_property_name,tc.property_id,p.name property_name,
   case when tc.used_at is not null then 'used' when tc.revoked_at is not null then 'revoked' when tc.expires_at<=now() then 'expired' else 'unused' end status
  from omg_private.trial_codes tc left join public.properties p on p.id=tc.property_id
 )x;
 return jsonb_build_object('ok',true,'codes',items);
end$$;
revoke all on function public.platform_trial_codes(text,jsonb) from public,anon;
grant execute on function public.platform_trial_codes(text,jsonb) to authenticated;

create function public.platform_system_notices(p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare tid uuid;t omg_private.system_notice_templates%rowtype;prop uuid;n int:=0;value text;placeholder text;send_token text:=gen_random_uuid()::text;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='save' then
  if p_data->>'event_key' not in('first_login','storage_warning','storage_full','trial_expiring','trial_expired','subscription_expiring','subscription_expired','service_updated','manual') then raise exception '알림 이벤트를 확인해주세요.';end if;
  value:=p_data->>'body';
  foreach placeholder in array array['사업장명','체험기간','제공용량','사용용량','종료일','남은일수','요금제','문의처'] loop value:=replace(value,'{'||placeholder||'}','');end loop;
  if value ~ '\{[^{}]+\}' then raise exception '지원하지 않는 치환 문구입니다. 화면의 자동입력 항목을 사용해주세요.';end if;
  tid:=nullif(p_data->>'id','')::uuid;
  if tid is null then insert into omg_private.system_notice_templates(event_key,title,body,enabled) values(p_data->>'event_key',btrim(p_data->>'title'),btrim(p_data->>'body'),coalesce((p_data->>'enabled')::boolean,true)) returning id into tid;
  else update omg_private.system_notice_templates set event_key=p_data->>'event_key',title=btrim(p_data->>'title'),body=btrim(p_data->>'body'),enabled=coalesce((p_data->>'enabled')::boolean,true),updated_at=now() where id=tid;
  if not found then raise exception '공지를 찾을 수 없습니다.';end if;end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'system_template_saved',jsonb_build_object('id',tid,'event_key',p_data->>'event_key'));
 elsif p_action='send' then
  select * into t from omg_private.system_notice_templates where id=(p_data->>'id')::uuid and enabled;
  if not found then raise exception '활성 공지를 선택해주세요.';end if;
  if jsonb_array_length(p_data->'property_ids') not between 1 and 500 then raise exception '수신 사업장을 선택해주세요.';end if;
  for prop in select distinct value::uuid from jsonb_array_elements_text(p_data->'property_ids') loop
   if not exists(select 1 from public.properties where id=prop) then raise exception '수신 사업장을 확인해주세요.';end if;
   n:=n+omg_private.emit_system_notice(prop,t.event_key,'manual:'||send_token,t.id);
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'system_notice_sent',jsonb_build_object('template_id',t.id,'count',n,'property_ids',p_data->'property_ids'));
 elsif p_action='retry' then
  update omg_private.system_notice_deliveries set attempts=0,last_attempt_at=null where delivered_at is null and id=(p_data->>'id')::bigint;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'sent',n,'templates',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') from omg_private.system_notice_templates x),
 'deliveries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select d.id,d.event_key,d.created_at,d.attempts,d.delivered_at,d.message_id,p.name property_name,nt.title,
  case when d.delivered_at is not null then 'sent' when d.attempts>=10 then 'failed' else 'pending' end status,
  (select count(*) from public.property_message_recipients where message_id=d.message_id) recipient_count,
  (select count(*) from public.property_message_recipients where message_id=d.message_id and read_at is not null) read_count
  from omg_private.system_notice_deliveries d join public.properties p on p.id=d.property_id join omg_private.system_notice_templates nt on nt.id=d.template_id order by d.created_at desc limit 100)x));
end$$;
revoke all on function public.platform_system_notices(text,jsonb) from public,anon;
grant execute on function public.platform_system_notices(text,jsonb) to authenticated;

-- Generate a small initial batch; terms come from the current operator policy.
insert into omg_private.trial_codes(code,trial_days,storage_limit_bytes,note,created_by)
select 'OMS'||upper(replace(gen_random_uuid()::text,'-','')),p.trial_days,p.storage_limit_bytes,'초기 체험 초대',
 (select user_id from public.platform_administrators order by created_at limit 1)
from omg_private.service_policy p cross join generate_series(1,5) where p.id;
do $$declare j record;begin for j in select jobid from cron.job where jobname in ('omg-service-policy-check','omg-system-notice-dispatch') loop perform cron.unschedule(j.jobid);end loop;end$$;
select cron.schedule('omg-service-policy-check','*/5 * * * *','select omg_private.refresh_service_notices()');
select cron.schedule('omg-system-notice-dispatch','* * * * *','select omg_private.dispatch_system_notices()');

create or replace function omg_private.guard_service_write() returns trigger language plpgsql security definer set search_path='' as $$
declare prop uuid;s jsonb;delta bigint:=0;has_photo boolean:=false;before_bytes bigint:=0;
begin
 if tg_table_schema='public' and tg_table_name='property_messages' then
  if new.sender_type='system' and new.source='platform_system' and exists(select 1 from omg_private.system_notice_deliveries where message_id=new.id and property_id=new.property_id) then return new;end if;
 end if;
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
 if tg_table_name='missions' then has_photo:=coalesce(new.description_photo,'')<>'';delta:=octet_length(coalesce(new.description_photo,''));if tg_op='UPDATE' then delta:=delta-octet_length(coalesce(old.description_photo,''));end if;
 elsif tg_table_name='mission_completions' then has_photo:=coalesce(new.photo_data_url,'')<>'';delta:=octet_length(coalesce(new.photo_data_url,''));if tg_op='UPDATE' then delta:=delta-octet_length(coalesce(old.photo_data_url,''));end if;
 elsif tg_table_name='work_reports' then has_photo:=new.payload::text like '%data:image/%';delta:=octet_length(new.payload::text);if tg_op='UPDATE' then delta:=delta-octet_length(old.payload::text);end if;
 elsif tg_table_name='property_messages' then has_photo:=new.message like '%data:image/%';delta:=octet_length(new.message);if tg_op='UPDATE' then delta:=delta-octet_length(old.message);end if;end if;
 if has_photo and delta>0 and not(s->>'exempt')::boolean and s->>'storage_action'='block_photos' and (s->>'used_bytes')::bigint+delta>(s->>'limit_bytes')::bigint then raise exception '저장 용량을 초과했습니다. 관리자에게 용량 추가를 요청해주세요.';end if;
 return new;
end$$;
revoke all on function omg_private.guard_service_write() from public,anon,authenticated;

create or replace function public.get_or_create_account_property()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_user_id uuid:=auth.uid();v_email text:=lower(coalesce(auth.jwt()->>'email',''));
  v_link public.account_properties%rowtype;v_business_id uuid;v_property_id uuid;v_owner_id uuid;
  v_business_code text;v_property_code text;v_property_name text;v_crypto_schema text;v_pin_hash text;
  v_management_number integer;v_created boolean:=false;v_code omg_private.trial_codes%rowtype;v_meta jsonb;v_required boolean;v_cutoff timestamptz;v_user_created timestamptz;v_owner_name text;
begin
  if v_user_id is null then
    return jsonb_build_object('ok',false,'code','authentication_required','message','계정 로그인이 필요합니다.');
  end if;
  perform pg_advisory_xact_lock(hashtext(v_user_id::text));
  select * into v_link from public.account_properties where user_id=v_user_id;
  if not found and v_email='oneminute01@naver.com' then
    select b.id,p.id,o.id into v_business_id,v_property_id,v_owner_id
    from public.businesses b join public.properties p on p.business_id=b.id
    join lateral(select id from public.owners where business_id=b.id and property_id=p.id and active order by created_at,id limit 1)o on true
    where b.code='omg' and p.code='seoul-station';
    if found then
      insert into public.account_properties(user_id,business_id,property_id,owner_id,onboarding_pending)
      values(v_user_id,v_business_id,v_property_id,v_owner_id,false)
      on conflict(user_id) do nothing;
      select * into v_link from public.account_properties where user_id=v_user_id;
    end if;
  end if;
  if not found then
    select * into v_code from omg_private.trial_codes where used_by=v_user_id for update;
    select raw_user_meta_data,created_at into v_meta,v_user_created from auth.users where id=v_user_id;
    select trial_code_required,trial_code_required_from into v_required,v_cutoff from omg_private.service_policy where id;
    if v_code.id is null and v_required and v_user_created>=v_cutoff then return jsonb_build_object('ok',false,'code','trial_code_required','message','체험코드가 확인되지 않았습니다. 운영자에게 문의해주세요.');end if;
    v_property_name:=coalesce(nullif(v_code.registration_property_name,''),nullif(left(btrim(v_meta->>'property_name'),80),''),'새 사업장');
    v_owner_name:=coalesce(nullif(v_code.registration_name,''),nullif(left(btrim(v_meta->>'name'),50),''),'관리자');
    v_created:=true;
    v_business_code:='account-'||replace(v_user_id::text,'-','');
    insert into public.businesses(name,code) values(v_property_name,v_business_code) returning id into v_business_id;
    perform pg_advisory_xact_lock(82424015);
    select coalesce(max(management_number),0)+1 into v_management_number from public.properties;
    insert into public.properties(business_id,name,code,rooms,room_types,management_number,notice)
    values(v_business_id,v_property_name,'main','[]'::jsonb,'[]'::jsonb,v_management_number,'') returning id into v_property_id;
    select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
    join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
    execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema)
      into v_pin_hash using '1234';
    insert into public.owners(business_id,property_id,display_name,login_id,pin_hash,active)
    values(v_business_id,v_property_id,v_owner_name,'admin',v_pin_hash,true) returning id into v_owner_id;
    insert into public.account_properties(user_id,business_id,property_id,owner_id,onboarding_pending)
    values(v_user_id,v_business_id,v_property_id,v_owner_id,true) returning * into v_link;
    if v_code.id is not null then
      update public.properties set trial_ends_at=v_code.used_at+make_interval(days=>v_code.trial_days),service_storage_limit=v_code.storage_limit_bytes,service_storage_warning=least(v_code.storage_limit_bytes,(select storage_warning_bytes from omg_private.service_policy where id)) where id=v_property_id;
      update omg_private.trial_codes set property_id=v_property_id where id=v_code.id;
    end if;
  end if;
  select b.code,p.code,p.name into v_business_code,v_property_code,v_property_name
  from public.businesses b join public.properties p on p.business_id=b.id
  where b.id=v_link.business_id and p.id=v_link.property_id;
  return jsonb_build_object('ok',true,'business_code',v_business_code,'property_code',v_property_code,
    'property_name',v_property_name,'onboarding_pending',v_link.onboarding_pending,'created',v_created,'service',omg_private.property_service_state(v_link.property_id));
end;
$$;


create or replace function public.start_account_admin_session(p_owner_id uuid,p_pin text) returns jsonb language plpgsql security definer set search_path='' as $$
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
end$$;

create or replace function public.platform_operations(p_action text default 'get',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare prop uuid;c omg_private.service_policy%rowtype;old jsonb;result jsonb;plan jsonb;name text;status text;
begin if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'code','platform_admin_required','message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='policy' then
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 update omg_private.service_policy set trial_days=(p_data->>'trial_days')::int,reminder_days=(p_data->>'reminder_days')::int,grace_days=(p_data->>'grace_days')::int,
 storage_limit_bytes=(p_data->>'storage_limit_bytes')::bigint,storage_warning_bytes=(p_data->>'storage_warning_bytes')::bigint,
 end_action=p_data->>'end_action',storage_action=p_data->>'storage_action',support_contact=btrim(coalesce(p_data->>'support_contact','')),updated_at=now() where id;
 for plan in select * from jsonb_array_elements(p_data->'plans') loop
 insert into omg_private.service_plans(code,name,monthly_price,storage_limit_bytes)
 values(plan->>'code',left(btrim(plan->>'name'),40),nullif(plan->>'monthly_price','')::integer,(plan->>'storage_limit_bytes')::bigint)
 on conflict(code) do update set name=excluded.name,monthly_price=excluded.monthly_price,storage_limit_bytes=excluded.storage_limit_bytes;
 if not found or btrim(plan->>'name')='' then raise exception '요금제 이름과 용량을 확인해주세요.';end if;end loop;
 insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'service_policy_updated',jsonb_build_object('before',old,'after',p_data));
 elsif p_action='customer' then
 prop:=(p_data->>'property_id')::uuid;select service_status into status from public.properties where id=prop;
 if status is null then return jsonb_build_object('ok',false,'message','고객을 찾을 수 없습니다.');end if;
 if not exists(select 1 from omg_private.service_plans where code=p_data->>'service_plan') then raise exception '요금제를 확인해주세요.';end if;
 select to_jsonb(p) into old from public.properties p where id=prop;
 result:=public.update_platform_property(prop,coalesce(p_data->>'service_status',status),coalesce(p_data->>'operator_note',''));if not(result->>'ok')::boolean then return result;end if;
 update public.properties set service_plan=p_data->>'service_plan',billing_exempt=coalesce((p_data->>'billing_exempt')::boolean,false),
 trial_ends_at=nullif(p_data->>'trial_ends_at','')::timestamptz,subscription_ends_at=nullif(p_data->>'subscription_ends_at','')::timestamptz,
 service_storage_limit=nullif(p_data->>'storage_limit_bytes','')::bigint,service_storage_warning=nullif(p_data->>'storage_warning_bytes','')::bigint where id=prop;
 if exists(select 1 from public.properties where id=prop and (service_storage_limit<1048576 or service_storage_warning<1 or service_storage_warning>service_storage_limit)) then raise exception '고객별 용량과 경고 기준을 확인해주세요.';end if;
 insert into public.platform_audit_logs(operator_user_id,property_id,action,detail) values(auth.uid(),prop,'customer_service_updated',jsonb_build_object('before',jsonb_build_object('plan',old->'service_plan','trial_ends_at',old->'trial_ends_at','subscription_ends_at',old->'subscription_ends_at','billing_exempt',old->'billing_exempt'),'after',p_data));
 perform omg_private.emit_system_notice(prop,'service_updated',gen_random_uuid()::text);
 elsif p_action not in('get','usage') then raise exception '지원하지 않는 요청입니다.';end if;
 result:=public.get_platform_dashboard();
 select to_jsonb(x) into old from omg_private.service_policy x where id;
 perform omg_private.refresh_service_notices();
 select coalesce(jsonb_agg((x.value)||jsonb_build_object('trial_code',(select code from omg_private.trial_codes where property_id=p.id),'service_plan',p.service_plan,'billing_exempt',p.billing_exempt,'subscription_ends_at',p.subscription_ends_at,'storage_limit_override',p.service_storage_limit,'storage_warning_override',p.service_storage_warning,'service',coalesce(n.state,omg_private.property_service_state(p.id))) order by p.management_number),'[]'::jsonb) into plan
 from jsonb_array_elements(result->'properties')x(value) join public.properties p on p.id=(x.value->>'property_id')::uuid left join omg_private.service_notices n on n.property_id=p.id;
 return result||jsonb_build_object('properties',plan,'policy',old,'plans',(select jsonb_agg(to_jsonb(x) order by code) from omg_private.service_plans x),'last_checked_at',(select max(checked_at) from omg_private.service_notices),'payment_connected',false);
end$$;
revoke all on function public.platform_operations(text,jsonb) from public,anon;grant execute on function public.platform_operations(text,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.get_reminder_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_message record;v_topics jsonb;v_mode text;v_name text;v_targets jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT m.*,p.management_number INTO v_message FROM public.property_messages m JOIN public.properties p ON p.id=m.property_id
 WHERE m.id=p_message_id AND m.source in('reminder','platform_system');
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT coalesce(jsonb_agg('property_'||v_message.management_number||'_'||
     CASE WHEN r.recipient_type='staff' THEN 'employee_'||r.employee_id ELSE 'owner_'||r.owner_id END),'[]'::jsonb)
 INTO v_topics FROM public.property_message_recipients r WHERE r.message_id=p_message_id;
 select coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림') into v_mode,v_name from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=v_message.property_id;
 if v_message.source='platform_system' then v_name:=v_name||' · 시스템';end if;
 v_targets:=omg_private.bot_recipient_modes(p_message_id,v_mode);
 RETURN jsonb_build_object('ok',true,'message_id',p_message_id,'message',v_message.message,'sender_label',v_name,'priority',case when v_mode='urgent' then 'urgent' else 'normal' end)||v_targets;
END $function$

;

revoke all on function public.get_or_create_account_property(),public.start_account_admin_session(uuid,text) from public,anon;
grant execute on function public.get_or_create_account_property(),public.start_account_admin_session(uuid,text) to authenticated;
revoke all on function public.get_reminder_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_reminder_push_dispatch(uuid) to service_role;

update omg_private.service_policy
set trial_code_required=true,
    trial_code_required_from=coalesce(trial_code_required_from,now())
where id;
