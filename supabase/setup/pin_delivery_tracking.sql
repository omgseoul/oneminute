-- PIN values never enter the booking cache or the delivery ledger. Salted fingerprints
-- are private equality checks, scoped to one reservation and its room/stay dates.
alter table omg_private.auto_message_rules add column pin_notice boolean not null default false;
update omg_private.auto_message_rules set pin_notice=true where messages::text like '%{{비밀번호}}%';
create table omg_private.booking_pin_state(
 property_id uuid not null references public.properties(id) on delete cascade, booking_id bigint not null,
 salt uuid not null default gen_random_uuid(), fingerprint text, configured boolean, observed_at timestamptz,
 primary key(property_id,booking_id));
create table omg_private.pin_delivery_events(
 id uuid primary key, property_id uuid not null references public.properties(id) on delete cascade, booking_id bigint not null,
 fingerprint text, booking_signature text, status text not null check(status in('sending','sent','failed','uncertain','external')),
 via text not null check(via in('auto','manual','external')), title text, language text, actor text, error text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index pin_delivery_booking on omg_private.pin_delivery_events(property_id,booking_id,created_at desc);
alter table omg_private.booking_pin_state enable row level security;
alter table omg_private.pin_delivery_events enable row level security;
revoke all on omg_private.booking_pin_state,omg_private.pin_delivery_events from public,anon,authenticated;
alter table omg_private.auto_message_deliveries add column pin_event_id uuid;

create function omg_private.pin_booking_signature(prop uuid,bid bigint) returns text language sql stable set search_path='' as $$
 select md5(jsonb_build_array(arrival,departure,data->'roomId',data->'unitId')::text)
 from omg_private.online_bookings where property_id=prop and id=bid
$$;
create function omg_private.pin_observe(prop uuid,bid bigint,pin text) returns text language plpgsql set search_path='' as $$
declare fp text;begin
 if not exists(select from omg_private.online_bookings where property_id=prop and id=bid) then raise exception '예약을 찾지 못했습니다.';end if;
 if pin is not null and pin !~ '^[A-Za-z0-9*#-]{4,32}$' then raise exception '비밀번호 형식을 확인해주세요.';end if;
 insert into omg_private.booking_pin_state(property_id,booking_id) values(prop,bid) on conflict do nothing;
 update omg_private.booking_pin_state set fingerprint=case when pin is not null then md5(salt::text||':'||pin) end,
 configured=pin is not null,observed_at=now() where property_id=prop and booking_id=bid returning fingerprint into fp;
 return fp;
end$$;
create function omg_private.pin_delivery_state(prop uuid,bid bigint,p_history boolean default false) returns jsonb language plpgsql stable set search_path='' as $$
declare b omg_private.online_bookings%rowtype;s omg_private.booking_pin_state%rowtype;e omg_private.pin_delivery_events%rowtype;
 d omg_private.auto_message_deliveries%rowtype;due timestamptz;tz text;state text:='unknown';hist jsonb;begin
 select * into b from omg_private.online_bookings where property_id=prop and id=bid;
 select * into s from omg_private.booking_pin_state where property_id=prop and booking_id=bid;
 select * into e from omg_private.pin_delivery_events where property_id=prop and booking_id=bid and status in('sent','external') order by created_at desc limit 1;
 if e.id is not null then
  state:=case when s.configured is null then 'unknown' when e.fingerprint=s.fingerprint and e.booking_signature=omg_private.pin_booking_signature(prop,bid) then 'sent' else 'resend' end;
 else
  select coalesce(timezone,'Asia/Seoul') into tz from public.properties where id=prop;
  select min(omg_private.auto_message_effective_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,tz)) into due
   from omg_private.auto_message_rules r where r.property_id=prop and r.enabled and r.pin_notice;
  select x.* into d from omg_private.auto_message_deliveries x join omg_private.auto_message_rules r on r.id=x.rule_id
   where x.property_id=prop and x.booking_id=bid and r.pin_notice order by x.updated_at desc limit 1;
  if b.status in('cancelled','black','inquiry') or b.departure<(now() at time zone tz)::date then state:='excluded';
  elsif exists(select from omg_private.pin_delivery_events x where x.property_id=prop and x.booking_id=bid and x.status in('sending','uncertain')) then state:='unknown';
  elsif d.status='failed' or exists(select from omg_private.pin_delivery_events x where x.property_id=prop and x.booking_id=bid and x.status='failed') then state:='failed';
  elsif d.status in('sent','uncertain') then state:='unknown'; -- historical sends lack evidence of the actual PIN
  elsif due>now() then state:='scheduled';
  elsif due is not null then state:='unsent';end if;
 end if;
 if p_history then
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into hist from (
  select id,status,via,title,language,coalesce((select display_name from public.owners where 'owner:'||id=actor),(select display_name from public.employees where 'employee:'||id=actor),actor) as actor,error,created_at,updated_at from omg_private.pin_delivery_events
  where property_id=prop and booking_id=bid order by created_at desc limit 20)x;
 end if;
 return jsonb_build_object('active',exists(select from omg_private.auto_message_rules where property_id=prop and enabled and pin_notice),'state',state,'configured',s.configured,'observed_at',s.observed_at,'due_at',due,'events',hist);
end$$;
create function public.pin_delivery_internal(p_action text,p_property uuid,p_data jsonb default '{}') returns jsonb
 language plpgsql security definer set search_path='' as $$
declare bid bigint:=(p_data->>'booking_id')::bigint;fp text;e omg_private.pin_delivery_events%rowtype;x jsonb;begin
 if p_action='observe_batch' then
  for x in select * from jsonb_array_elements(p_data->'items') loop perform omg_private.pin_observe(p_property,(x->>'booking_id')::bigint,x->>'pin');end loop;
  return jsonb_build_object('ok',true);
 end if;
 if not exists(select from omg_private.online_bookings where property_id=p_property and id=bid) then raise exception '예약을 찾지 못했습니다.';end if;
 if p_action in('observe','begin','external') then
  fp:=omg_private.pin_observe(p_property,bid,p_data->>'pin');
  if p_action in('begin','external') then
   if fp is null then raise exception '비밀번호가 설정되지 않았습니다.';end if;
   insert into omg_private.pin_delivery_events(id,property_id,booking_id,fingerprint,booking_signature,status,via,title,language,actor)
    values((p_data->>'id')::uuid,p_property,bid,fp,omg_private.pin_booking_signature(p_property,bid),case when p_action='external' then 'external' else 'sending' end,
     case when p_action='external' then 'external' else 'manual' end,left(p_data->>'title',80),p_data->>'language',p_data->>'actor') on conflict(id) do nothing;
   select * into e from omg_private.pin_delivery_events where id=(p_data->>'id')::uuid;
   if e.property_id<>p_property or e.booking_id<>bid then raise exception '다른 예약의 발송 기록입니다.';end if;
  end if;
 elsif p_action='finish' then
  if p_data->>'status' not in('sent','failed','uncertain') then raise exception '발송 상태를 확인해주세요.';end if;
  update omg_private.pin_delivery_events set status=p_data->>'status',error=left(p_data->>'error',200),updated_at=now()
   where id=(p_data->>'id')::uuid and property_id=p_property and booking_id=bid and status='sending';
 elsif p_action<>'state' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'pin_delivery',omg_private.pin_delivery_state(p_property,bid,true));
end$$;
revoke all on function omg_private.pin_booking_signature(uuid,bigint),omg_private.pin_observe(uuid,bigint,text),omg_private.pin_delivery_state(uuid,bigint,boolean),public.pin_delivery_internal(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.pin_delivery_internal(text,uuid,jsonb) to service_role;

-- Attach PIN evidence to the same lease that authorizes the actual provider send.
do $migration$
declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.auto_message_owner(uuid,text,jsonb)'::regprocedure);
 anchor:='revision=auto_message_rules.revision+1,updated_at=now();';
 if strpos(def,anchor)=0 then raise exception 'Missing auto rule save hook';end if;
 def:=replace(def,anchor,anchor||$hook$
   update omg_private.auto_message_rules set pin_notice=coalesce((p_data->>'pin_notice')::boolean,false) or messages::text like '%{{비밀번호}}%' where id=rid;
 $hook$);execute def;
 def:=pg_get_functiondef('omg_private.auto_message_internal(text,jsonb)'::regprocedure);
 anchor:='  update omg_private.auto_message_deliveries set status=''sending''';
 if strpos(def,anchor)=0 then raise exception 'Missing auto send hook';end if;
 def:=replace(def,anchor,$hook$
  if nullif(p_data->>'pin','') is not null then
   perform omg_private.pin_observe(j.property_id,j.booking_id,p_data->>'pin');
   insert into omg_private.pin_delivery_events(id,property_id,booking_id,fingerprint,booking_signature,status,via,title,language)
    select gen_random_uuid(),j.property_id,j.booking_id,s.fingerprint,omg_private.pin_booking_signature(j.property_id,j.booking_id),'sending','auto',j.title,p_data->>'language'
    from omg_private.booking_pin_state s where s.property_id=j.property_id and s.booking_id=j.booking_id
    returning id into j.pin_event_id;
   update omg_private.auto_message_deliveries set pin_event_id=j.pin_event_id where id=j.id;
  end if;
 $hook$||anchor);
 anchor:='   update omg_private.auto_message_deliveries set status=p_data->>''status'',error=';
 if strpos(def,anchor)=0 then raise exception 'Missing auto settlement hook';end if;
 def:=replace(def,anchor,$hook$
   update omg_private.pin_delivery_events set status=p_data->>'status',error=left(p_data->>'error',200),updated_at=now()
    where id=j.pin_event_id and status='sending';
 $hook$||anchor);execute def;
 -- Add only a compact status to list rows. Detailed evidence remains an explicit authorized read.
 def:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 anchor:='select b.* from omg_private.online_bookings b';
 if strpos(def,anchor)=0 then raise exception 'Missing check-in list hook';end if;
 execute replace(def,anchor,'select b.*,omg_private.pin_delivery_state(b.property_id,b.id)-''events'' as pin_delivery from omg_private.online_bookings b');
 def:=pg_get_functiondef('omg_private.online_booking_data(uuid,text,jsonb,text)'::regprocedure);
 anchor:='b.status,b.channel,b.data,';
 if strpos(def,anchor)=0 then raise exception 'Missing booking DATA hook';end if;
 execute replace(def,anchor,anchor||'omg_private.pin_delivery_state(b.property_id,b.id)-''events'' as pin_delivery,');
end$migration$;

do $migration$ declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.iot_internal(text,uuid,jsonb)'::regprocedure);
 anchor:=$n$   if p_data->>'status' in('done','failed','revoked') then perform omg_private.iot_notice(j.id,p_data->>'status');end if;$n$;
 if strpos(def,anchor)=0 then raise exception 'Missing IOT finish hook';end if;
 execute replace(def,anchor,$n$   if p_data->>'status'='done' and nullif(j.state->>'pin','') is not null then perform omg_private.pin_observe(p_property,j.booking_id,j.state->>'pin');end if;
   if p_data->>'status'='revoked' then perform omg_private.pin_observe(p_property,j.booking_id,null);end if;
$n$||anchor);
end$migration$;

-- Reconcile uncertain/failed lease expiry as well as the normal worker finish.
create function omg_private.pin_auto_settle() returns trigger language plpgsql set search_path='' as $$begin
 if new.pin_event_id is not null and new.status in('sent','failed','uncertain') then
  update omg_private.pin_delivery_events set status=new.status,error=left(new.error,200),updated_at=now() where id=new.pin_event_id and status='sending';
 end if;return new;
end$$;
revoke all on function omg_private.pin_auto_settle() from public,anon,authenticated;
create trigger pin_auto_settle after update of status on omg_private.auto_message_deliveries for each row execute function omg_private.pin_auto_settle();
