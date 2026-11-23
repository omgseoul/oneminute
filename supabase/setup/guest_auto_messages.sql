-- Per-property, owner-managed scheduled guest messages. No rules are enabled by this migration.
begin;
create table omg_private.auto_message_rules (
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id),
 title text not null check(length(btrim(title)) between 1 and 80),
 trigger text not null check(trigger in('booking','booking_after','checkin_before','checkin_after')),
 days integer not null default 0 check(days between 0 and 365), send_time time not null default '09:00',
 messages jsonb not null, enabled boolean not null default false,
 enabled_from timestamptz not null default now(), revision integer not null default 1,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index auto_message_rules_enabled on omg_private.auto_message_rules(property_id) where enabled;
create table omg_private.auto_message_deliveries (
 id uuid primary key default gen_random_uuid(), rule_id uuid not null references omg_private.auto_message_rules(id),
 property_id uuid not null references public.properties(id), booking_id bigint not null,
 title text not null, revision integer not null, due_at timestamptz not null,
 status text not null default 'waiting' check(status in('waiting','preparing','sending','sent','failed','uncertain','skipped')),
 lease uuid, leased_until timestamptz, next_at timestamptz not null default now(),
 language text, error text, attempts integer not null default 0,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(rule_id,booking_id)
);
create index auto_message_deliveries_pending on omg_private.auto_message_deliveries(next_at) where status in('waiting','preparing');
alter table omg_private.auto_message_rules enable row level security;
alter table omg_private.auto_message_deliveries enable row level security;
revoke all on omg_private.auto_message_rules,omg_private.auto_message_deliveries from public,anon,authenticated;

create function omg_private.auto_message_due(p_trigger text,p_days integer,p_time time,p_booked timestamptz,p_arrival date,p_timezone text)
returns timestamptz language sql stable set search_path='' as $$
 select case p_trigger when 'booking' then p_booked when 'booking_after' then p_booked+make_interval(days=>p_days)
 when 'checkin_before' then (p_arrival-p_days+p_time) at time zone p_timezone
 when 'checkin_after' then (p_arrival+p_days+p_time) at time zone p_timezone end
$$;

create function omg_private.auto_message_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a jsonb; home uuid; r omg_private.auto_message_rules%rowtype; k text; v jsonb; rid uuid; begin
 a:=omg_private.guest_actor(p_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 자동메시지 설정 권한이 없습니다.';end if;
 if p_action in('save','toggle') then
  rid:=(p_data->>'id')::uuid;
  if rid is null then raise exception '메시지 식별자를 확인해주세요.';end if;
  select * into r from omg_private.auto_message_rules where id=rid for update;
  if found and r.property_id<>home then raise exception '이 지점의 메시지가 아닙니다.';end if;
  if r.id is not null and r.revision<>coalesce((p_data->>'revision')::int,0) then raise exception '다른 화면에서 수정되었습니다. 다시 열어주세요.';end if;
  if p_action='toggle' then
   if r.id is null then raise exception '메시지를 찾지 못했습니다.';end if;
   update omg_private.auto_message_rules set enabled=(p_data->>'enabled')::boolean,
    enabled_from=case when not enabled and (p_data->>'enabled')::boolean then now() else enabled_from end,
    revision=revision+1,updated_at=now() where id=rid;
  else
   if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 80 then raise exception '제목을 1~80자로 입력해주세요.';end if;
   if coalesce(p_data->>'trigger','') not in('booking','booking_after','checkin_before','checkin_after') or coalesce((p_data->>'days')::integer,-1) not between 0 and 365 then raise exception '발송 시기와 일수를 확인해주세요.';end if;
   if jsonb_typeof(p_data->'messages') is distinct from 'object' or length(btrim(coalesce(p_data->'messages'->>'common',''))) not between 1 and 4000 then raise exception '공통 메시지를 1~4,000자로 입력해주세요.';end if;
   for k,v in select * from jsonb_each(p_data->'messages') loop
    if k not in('common','ja','en','zh-CN','zh-TW','ko','fr','de','es','it','pt','ru','th','vi','id') or jsonb_typeof(v)<>'string' or length(btrim(v#>>'{}')) not between 1 and 4000 then raise exception '언어별 메시지를 확인해주세요.';end if;
    if exists(select 1 from regexp_matches(v#>>'{}','\{\{([^{}]+)\}\}','g') m where m[1] not in('이름','체크인','체크아웃','비밀번호','객실')) then raise exception '지원하지 않는 자동 입력 요소입니다.';end if;
   end loop;
   if coalesce((p_data->>'enabled')::boolean,false) and not exists(select 1 from omg_private.online_connections where property_id=home and vault_id is not null and beds_property_id is not null) then raise exception '먼저 이 지점의 Beds24 연결을 설정해주세요.';end if;
   insert into omg_private.auto_message_rules(id,property_id,title,trigger,days,send_time,messages,enabled)
    values(rid,home,btrim(p_data->>'title'),p_data->>'trigger',(p_data->>'days')::integer,coalesce(nullif(p_data->>'send_time','')::time,'09:00'),p_data->'messages',coalesce((p_data->>'enabled')::boolean,false))
   on conflict(id) do update set title=excluded.title,trigger=excluded.trigger,days=excluded.days,send_time=excluded.send_time,messages=excluded.messages,enabled=excluded.enabled,
    enabled_from=case when not auto_message_rules.enabled and excluded.enabled then now() else auto_message_rules.enabled_from end,
    revision=auto_message_rules.revision+1,updated_at=now();
  end if;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'property_id',home,'timezone',(select timezone from public.properties where id=home),
 'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p where p.id=(a->>'property_id')::uuid or (omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages'))),
 'rules',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from omg_private.auto_message_rules x where property_id=home),
 'logs',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select id,booking_id,title,status,language,error,updated_at from omg_private.auto_message_deliveries where property_id=home order by updated_at desc limit 50)x));
end$$;

create function omg_private.auto_message_internal(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare j omg_private.auto_message_deliveries%rowtype; r omg_private.auto_message_rules%rowtype; b omg_private.online_bookings%rowtype; due timestamptz; begin
 if p_action='claim' then
  -- Ambiguous sends are never retried automatically.
  update omg_private.auto_message_deliveries set status='uncertain',error='발송 결과 확인 필요 · 게스트 대화를 확인해주세요.',updated_at=now() where status='sending' and updated_at<now()-interval '3 minutes';
  update omg_private.auto_message_deliveries set status='waiting',lease=null where status='preparing' and leased_until<now();
  update omg_private.auto_message_deliveries set status='skipped',error='발송 가능 기간이 지났습니다.',updated_at=now() where status='waiting' and due_at<now()-interval '24 hours';
  insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at)
   select rule_row.id,rule_row.property_id,booking_row.id,rule_row.title,rule_row.revision,s.due from omg_private.auto_message_rules rule_row
   join public.properties p on p.id=rule_row.property_id join omg_private.online_bookings booking_row on booking_row.property_id=rule_row.property_id
   cross join lateral(select omg_private.auto_message_due(rule_row.trigger,rule_row.days,rule_row.send_time,booking_row.booked_at,booking_row.arrival,coalesce(p.timezone,'Asia/Seoul')) due)s
   where rule_row.enabled and booking_row.status in('new','confirmed') and booking_row.departure>=(now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date
   and s.due>=rule_row.enabled_from and s.due<=now() and s.due>now()-interval '24 hours'
   and not exists(select 1 from omg_private.auto_message_deliveries delivered where delivered.rule_id=rule_row.id and delivered.booking_id=booking_row.id)
   order by s.due limit 300 on conflict(rule_id,booking_id) do nothing;
  select * into j from omg_private.auto_message_deliveries where status='waiting' and next_at<=now() order by next_at,created_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  update omg_private.auto_message_deliveries set status='preparing',lease=gen_random_uuid(),leased_until=now()+interval '90 seconds',attempts=attempts+1,updated_at=now() where id=j.id returning * into j;
  select * into r from omg_private.auto_message_rules where id=j.rule_id;
  return to_jsonb(j)||jsonb_build_object('rule',to_jsonb(r),'timezone',(select timezone from public.properties where id=j.property_id));
 end if;
 select * into j from omg_private.auto_message_deliveries where id=(p_data->>'id')::uuid for update;
 if not found or j.lease is distinct from (p_data->>'lease')::uuid then return jsonb_build_object('skip',true);end if;
 if p_action='prepare' then
  if j.status<>'preparing' or j.leased_until<now() then return jsonb_build_object('skip',true);end if;
  select * into r from omg_private.auto_message_rules where id=j.rule_id for update;
  select * into b from omg_private.online_bookings where property_id=j.property_id and id=j.booking_id;
  due:=omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce((select timezone from public.properties where id=j.property_id),'Asia/Seoul'));
  if not r.enabled or b.status not in('new','confirmed') or due is null or due<r.enabled_from then
   update omg_private.auto_message_deliveries set status='skipped',error='설정 중지 또는 예약 변경',updated_at=now() where id=j.id;
   return jsonb_build_object('skip',true);
  end if;
  if r.revision<>j.revision or due>now() or due is distinct from j.due_at then
   update omg_private.auto_message_deliveries set status='waiting',revision=r.revision,title=r.title,due_at=due,next_at=greatest(now()+interval '1 minute',due),lease=null,updated_at=now() where id=j.id;
   return jsonb_build_object('skip',true);
  end if;
  update omg_private.auto_message_deliveries set status='sending',language=p_data->>'language',updated_at=now() where id=j.id;
  return jsonb_build_object('ok',true);
 elsif p_action='finish' then
  if j.status='preparing' and p_data->>'status' in('waiting','skipped') then
   update omg_private.auto_message_deliveries set status=p_data->>'status',next_at=now()+interval '5 minutes',lease=null,error=left(p_data->>'error',200),updated_at=now() where id=j.id;
  elsif j.status='sending' and p_data->>'status' in('sent','failed','uncertain') then
   update omg_private.auto_message_deliveries set status=p_data->>'status',error=left(p_data->>'error',200),updated_at=now() where id=j.id;
  end if;
 else raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true);
end$$;
create function public.auto_message_owner(p_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.auto_message_owner(p_token,p_action,p_data)$$;
create function public.auto_message_internal(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.auto_message_internal(p_action,p_data)$$;
revoke all on function public.auto_message_owner(uuid,text,jsonb),public.auto_message_internal(text,jsonb),omg_private.auto_message_owner(uuid,text,jsonb),omg_private.auto_message_internal(text,jsonb),omg_private.auto_message_due(text,integer,time,timestamptz,date,text) from public,anon,authenticated;
grant execute on function public.auto_message_owner(uuid,text,jsonb),public.auto_message_internal(text,jsonb),omg_private.auto_message_owner(uuid,text,jsonb),omg_private.auto_message_internal(text,jsonb) to service_role;
commit;
