-- Durable, owner-scoped cleaning turnaround ETA extraction. No guest replies or alerts.
create table if not exists omg_private.online_arrival_estimates(
 property_id uuid not null,booking_id bigint not null,arrival_day date not null,room_key text not null,
 input_hash text not null,time_from text,time_to text,evidence_kind text,evidence_ref text,
 checked_at timestamptz not null default now(),primary key(property_id,booking_id),
 foreign key(property_id,booking_id) references omg_private.online_bookings(property_id,id) on delete cascade,
 check(time_from is null or time_from ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),check(time_to is null or time_to ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')
);
create table if not exists omg_private.online_arrival_runs(
 property_id uuid not null references public.properties(id) on delete cascade,day date not null,id uuid not null default gen_random_uuid(),
 status text not null default 'running' check(status in('running','completed','failed')),leased_until timestamptz not null default now()+interval '5 minutes',
 bookings_checked boolean not null default false,checked_at timestamptz,error text,inputs jsonb not null default '[]',
 period date,reserved_micro bigint not null default 0,charged_micro bigint not null default 0,primary key(property_id,day)
);
alter table omg_private.online_arrival_estimates enable row level security;
alter table omg_private.online_arrival_runs enable row level security;
revoke all on omg_private.online_arrival_estimates,omg_private.online_arrival_runs from public,anon,authenticated;
create index if not exists online_arrival_date on omg_private.online_arrival_estimates(property_id,arrival_day);
create index if not exists online_booking_departure on omg_private.online_bookings(property_id,departure);

create or replace function omg_private.online_arrival_unit(prop uuid,booking_data jsonb,bid bigint) returns text language plpgsql stable security invoker set search_path='' as $$
declare room jsonb;units jsonb;uid text;rid text;begin
 rid:=nullif(booking_data->>'roomId','');uid:=nullif(booking_data->>'unitId','');
 if rid is null or rid !~ '^[1-9][0-9]*$' then return 'unassigned:'||bid;end if;
 if uid is null or uid !~ '^[1-9][0-9]*$' then
  select r into room from omg_private.online_connections c cross join lateral jsonb_array_elements(c.properties)p cross join lateral jsonb_array_elements(coalesce(p->'roomTypes','[]'))r where c.property_id=prop and p->>'id'=c.beds_property_id::text and r->>'id'=rid;
  units:=coalesce(room->'units','[]');
  if jsonb_array_length(units)=1 and greatest(coalesce((room->>'qty')::int,0),jsonb_array_length(units))=1 then uid:=units->0->>'id';else return 'unassigned:'||bid;end if;
 end if;
 return 'unit:'||rid||':'||uid;
end$$;

create or replace function omg_private.online_arrival_candidates(prop uuid,v_day date) returns table(booking_id bigint,room_key text) language sql stable security invoker set search_path='' as $$
 with departing as(select distinct omg_private.online_arrival_unit(prop,b.data,b.id) k from omg_private.online_bookings b where b.property_id=prop and b.departure=v_day and b.status in('new','confirmed')),
 incoming as(select b.id,omg_private.online_arrival_unit(prop,b.data,b.id) k from omg_private.online_bookings b where b.property_id=prop and b.arrival=v_day and b.status in('new','confirmed'))
 select min(i.id),i.k from incoming i join departing d on d.k=i.k where i.k like 'unit:%' group by i.k having count(*)=1
$$;

create or replace function omg_private.online_arrivals(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare auth jsonb;prop uuid;v_day date;r omg_private.online_arrival_runs%rowtype;v_period date;v_res bigint;v_cost bigint;balance bigint;it bigint;ot bigint;ct bigint;budget bigint;x jsonb;b record;items jsonb;begin
 auth:=omg_private.online_owner(p_token,'auth',jsonb_build_object('property_id',p_data->>'property_id'));prop:=(auth->>'property_id')::uuid;v_day:=(p_data->>'day')::date;
 if v_day is null then raise exception '조회 날짜를 확인해주세요.';end if;
 if p_action='read' then
  select * into r from omg_private.online_arrival_runs where property_id=prop and day=v_day;
  with departing as(select distinct omg_private.online_arrival_unit(prop,q.data,q.id) k from omg_private.online_bookings q where q.property_id=prop and q.departure=v_day and q.status in('new','confirmed')),
  incoming as(select q.id,omg_private.online_arrival_unit(prop,q.data,q.id) k from omg_private.online_bookings q where q.property_id=prop and q.arrival=v_day and q.status in('new','confirmed')),
  matched as(select d.k,count(i.id) n,min(i.id) bid,exists(select 1 from omg_private.online_bookings pending where pending.property_id=prop and pending.arrival=v_day and pending.status in('new','confirmed') and pending.data->>'roomId'=split_part(d.k,':',2) and omg_private.online_arrival_unit(prop,pending.data,pending.id) like 'unassigned:%') unallocated from departing d left join incoming i on i.k=d.k and d.k like 'unit:%' group by d.k)
  select coalesce(jsonb_agg(jsonb_build_object('room_key',m.k,'booking_id',m.bid,'state',case when m.k like 'unit:%' and m.n=0 and r.bookings_checked and not m.unallocated then 'no_checkin' when m.n=1 and e.time_from is not null then 'known' else 'unknown' end,'time_from',case when m.n=1 then e.time_from end,'time_to',case when m.n=1 then e.time_to end,'checked_at',e.checked_at)),'[]') into items from matched m left join omg_private.online_arrival_estimates e on e.property_id=prop and e.booking_id=m.bid and e.arrival_day=v_day and e.room_key=m.k;
  return jsonb_build_object('ok',true,'items',items,'status',case when r.status='running' and r.leased_until<now() then 'failed' else coalesce(r.status,'idle') end,'error',case when r.status='running' and r.leased_until<now() then '확인이 중단되었습니다. 다시 눌러주세요.' else r.error end,'checked_at',r.checked_at);
 end if;
 -- Serialize a single day without locking unrelated properties or checkout dates.
 perform pg_advisory_xact_lock(hashtextextended(prop::text||':'||v_day,1514));
 select * into r from omg_private.online_arrival_runs where property_id=prop and day=v_day for update;
 if p_action='start' then
  if r.status='running' and r.leased_until>now() then return jsonb_build_object('ok',true,'id',r.id,'skip',true);end if;
  if r.status='completed' and r.checked_at>now()-interval '30 seconds' then return jsonb_build_object('ok',true,'id',r.id,'skip',true);end if;
  -- An interrupted provider call is conservatively settled once before a retry.
  if r.reserved_micro>0 then
   update omg_private.ai_usage_month set reserved_micro=greatest(0,reserved_micro-r.reserved_micro),used_micro=used_micro+r.reserved_micro,responses=responses+1 where property_id=prop and month=r.period;
  end if;
  insert into omg_private.online_arrival_runs(property_id,day)values(prop,v_day) on conflict(property_id,day)do update set id=gen_random_uuid(),status='running',bookings_checked=false,leased_until=now()+interval '5 minutes',error=null,inputs='[]',period=null,reserved_micro=0 returning * into r;
  return jsonb_build_object('ok',true,'id',r.id,'skip',false);
 end if;
 if r.id is distinct from (p_data->>'run_id')::uuid or r.status<>'running' or r.leased_until<now() then return jsonb_build_object('ok',true,'skip',true);end if;
 if p_action='synced' then
  update omg_private.online_arrival_runs set bookings_checked=true where property_id=prop and day=v_day;return jsonb_build_object('ok',true);
 elsif p_action='candidates' then
  select coalesce(jsonb_agg(jsonb_build_object('booking_id',c.booking_id,'room_key',c.room_key,'input_hash',e.input_hash,'time_from',e.time_from,'time_to',e.time_to)),'[]') into items from omg_private.online_arrival_candidates(prop,v_day)c left join omg_private.online_arrival_estimates e on e.property_id=prop and e.booking_id=c.booking_id and e.arrival_day=v_day and e.room_key=c.room_key;
  return jsonb_build_object('ok',true,'items',items);
 elsif p_action='prepare' then
  if r.reserved_micro>0 then return jsonb_build_object('ok',true,'skip',true);end if;
  items:=p_data->'items';
  if jsonb_typeof(items)<>'array' or jsonb_array_length(items) not between 1 and 40 or exists(select 1 from jsonb_array_elements(items)i where coalesce(i->>'hash','') !~ '^[a-f0-9]{64}$' or not exists(select 1 from omg_private.online_arrival_candidates(prop,v_day)c where c.booking_id=(i->>'booking_id')::bigint)) then raise exception '도착예상 대상 예약을 확인해주세요.';end if;
  if (p_data->>'input_bytes')::int not between 1 and 240000 then raise exception '분석할 대화가 너무 깁니다.';end if;
  if not exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null) then raise exception '운영센터의 AI 연결을 확인해주세요.';end if;
  v_period:=omg_private.ai_month();v_res:=ceil(((p_data->>'input_bytes')::int+20000)*0.125+4096*0.5)::bigint;
  select balance_micro into balance from omg_private.ai_wallets where property_id=prop and enabled for update;
  insert into omg_private.ai_usage_month(property_id,month)values(prop,v_period)on conflict do nothing;
  if balance is null or balance-coalesce((select sum(reserved_micro) from omg_private.ai_jobs where property_id=prop and status='leased'),0)<v_res or (select w.monthly_limit_micro-u.used_micro-u.reserved_micro from omg_private.ai_wallets w join omg_private.ai_usage_month u using(property_id) where w.property_id=prop and u.month=v_period)<v_res then raise exception 'AI 크레딧 또는 월 사용 한도를 확인해주세요.';end if;
  update omg_private.ai_wallets set balance_micro=balance_micro-v_res where property_id=prop;
  update omg_private.ai_usage_month set reserved_micro=reserved_micro+v_res where property_id=prop and month=v_period;
  update omg_private.online_arrival_runs set inputs=items,period=v_period,reserved_micro=v_res where property_id=prop and day=v_day;
  return jsonb_build_object('ok',true);
 elsif p_action='finish' then
  it:=greatest(0,coalesce((p_data->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((p_data->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((p_data->>'cached_tokens')::bigint,0)));
  v_cost:=least(r.reserved_micro,case when coalesce((p_data->>'estimated')::boolean,false) then r.reserved_micro else ceil((it-ct)*0.10+ct*0.01+ot*0.50)::bigint end);
  if r.reserved_micro>0 then
   perform 1 from omg_private.ai_wallets where property_id=prop for update;
   update omg_private.ai_wallets set balance_micro=balance_micro+r.reserved_micro-v_cost,updated_at=now() where property_id=prop;
   update omg_private.ai_usage_month set reserved_micro=greatest(0,reserved_micro-r.reserved_micro),used_micro=used_micro+v_cost,responses=responses+case when v_cost>0 then 1 else 0 end,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=prop and month=r.period;
  end if;
  for x in select value from jsonb_array_elements(coalesce(p_data->'results','[]')) loop
   select c.* into b from omg_private.online_arrival_candidates(prop,v_day)c where c.booking_id=(x->>'booking_id')::bigint;
   if not found or not exists(select 1 from jsonb_array_elements(r.inputs)i where i->>'booking_id'=x->>'booking_id' and i->>'hash'=x->>'hash') then continue;end if;
   if nullif(x->>'time_from','') is not null and (x->>'time_from' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(x->>'evidence_kind','') not in('message','note','arrival_field')) then continue;end if;
   if nullif(x->>'time_to','') is not null and (x->>'time_to' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or x->>'time_to'<x->>'time_from') then continue;end if;
   insert into omg_private.online_arrival_estimates(property_id,booking_id,arrival_day,room_key,input_hash,time_from,time_to,evidence_kind,evidence_ref)
   values(prop,b.booking_id,v_day,b.room_key,x->>'hash',nullif(x->>'time_from',''),nullif(x->>'time_to',''),left(x->>'evidence_kind',20),left(x->>'evidence_ref',80))
   on conflict(property_id,booking_id)do update set arrival_day=excluded.arrival_day,room_key=excluded.room_key,input_hash=excluded.input_hash,
    time_from=case when excluded.time_from is not null then excluded.time_from when online_arrival_estimates.arrival_day=excluded.arrival_day and online_arrival_estimates.room_key=excluded.room_key then online_arrival_estimates.time_from end,
    time_to=case when excluded.time_from is not null then excluded.time_to when online_arrival_estimates.arrival_day=excluded.arrival_day and online_arrival_estimates.room_key=excluded.room_key then online_arrival_estimates.time_to end,
    evidence_kind=case when excluded.time_from is not null then excluded.evidence_kind else online_arrival_estimates.evidence_kind end,evidence_ref=case when excluded.time_from is not null then excluded.evidence_ref else online_arrival_estimates.evidence_ref end,checked_at=now();
  end loop;
  update omg_private.online_arrival_runs set status=case when nullif(p_data->>'error','') is null then 'completed' else 'failed' end,checked_at=now(),error=left(p_data->>'error',200),charged_micro=v_cost,reserved_micro=0 where property_id=prop and day=v_day;
  return jsonb_build_object('ok',true);
 end if;
 raise exception '지원하지 않는 도착예상 요청입니다.';
end$$;
create or replace function public.online_arrivals(p_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.online_arrivals(p_token,p_action,p_data)$$;
revoke all on function omg_private.online_arrival_unit(uuid,jsonb,bigint),omg_private.online_arrival_candidates(uuid,date),omg_private.online_arrivals(uuid,text,jsonb),public.online_arrivals(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function omg_private.online_arrival_unit(uuid,jsonb,bigint),omg_private.online_arrival_candidates(uuid,date),omg_private.online_arrivals(uuid,text,jsonb),public.online_arrivals(uuid,text,jsonb) to service_role;
