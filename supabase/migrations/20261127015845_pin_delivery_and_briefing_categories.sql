begin;
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

create function public.staff_account_quota(p_access_token uuid,p_property_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if not coalesce(omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings'),false) then raise exception '계정관리 권한이 필요합니다.';end if;
 return (select jsonb_build_object('limit',coalesce(sp.employee_limit,10),'count',(select count(*) from public.employees e where e.property_id=p.id and e.active and e.role<>'owner'))
 from public.properties p left join omg_private.service_plans sp on sp.code=p.service_plan where p.id=p_property_id);
end$$;
revoke all on function public.staff_account_quota(uuid,uuid) from public;
grant execute on function public.staff_account_quota(uuid,uuid) to anon,authenticated;

create function omg_private.iot_notice_context(p_message uuid,p_property uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('channel',b.channel,'reference',b.data->>'apiReference','booking_id',b.id)
 from omg_private.iot_notices n join omg_private.iot_jobs j on j.id=n.job_id
 join omg_private.online_bookings b on b.property_id=j.property_id and b.id=j.booking_id
 where n.message_id=p_message and j.property_id=p_property
$$;
revoke all on function omg_private.iot_notice_context(uuid,uuid) from public,anon,authenticated;
do $migration$ declare def text;signature text;needle text:=$n$'message_id',m.id,'property_id',m.property_id,$n$;begin
 for signature in select unnest(array['public.list_property_messages(uuid)','public.list_notification_bot_messages(uuid,timestamptz,uuid)']) loop
  def:=pg_get_functiondef(signature::regprocedure);
  if strpos(def,needle)=0 then raise exception 'Missing message metadata hook';end if;
  execute replace(def,needle,needle||$n$'iot_booking',case when v_is_owner and m.source='iot_lock' then omg_private.iot_notice_context(m.id,m.property_id) else null end,$n$);
 end loop;
 def:=pg_get_functiondef('omg_private.iot_notice(uuid,text)'::regprocedure);
 needle:=$n$||E'\n숙박: '$n$;
 if strpos(def,needle)=0 then raise exception 'Missing IOT notice hook';end if;
 execute replace(def,needle,$n$||E'\n예약사이트: '||coalesce(nullif(b.channel,''),'미확인')||E'\n사이트 예약번호: '||coalesce(nullif(b.data->>'apiReference',''),'-')||E'\nBeds24 예약번호: '||j.booking_id$n$||needle);
end$migration$;

alter table omg_private.briefing_settings add column categories jsonb;
alter table omg_private.briefing_deliveries add column categories text[];
-- Preserve explicitly selected people, while defaulting role-based delivery to their own work.
update omg_private.briefing_settings s set categories=(select jsonb_object_agg(k,jsonb_build_object('enabled',true,'targets',
 to_jsonb(array['manager',case when k='checkin' then 'reservation' else k end])||
 to_jsonb(array(select t from unnest(s.notify_targets)t where t ~ '^[0-9a-f-]{36}$'))||
 coalesce((select jsonb_agg('owner:'||o.id) from public.owners o where o.active and o.property_id<>s.property_id and omg_private.briefing_can_receive(s.property_id,o.property_id) and not ('skip-owner:'||o.id=any(s.notify_targets))),'[]')))
 from unnest(array['reservation','onsite','cleaning','checkin'])k);
alter table omg_private.briefing_settings alter column categories set default '{"reservation":{"enabled":true,"targets":["manager","reservation"]},"onsite":{"enabled":true,"targets":["manager","onsite"]},"cleaning":{"enabled":true,"targets":["manager","cleaning"]},"checkin":{"enabled":true,"targets":["manager","reservation"]}}';
alter table omg_private.briefing_settings alter column categories set not null;

create function omg_private.briefing_validate_categories(prop uuid,cfg jsonb) returns jsonb language plpgsql set search_path='' as $$
declare k text;c jsonb;t text;begin
 if jsonb_typeof(cfg) is distinct from 'object' or (select count(*) from jsonb_object_keys(cfg))<>4 then raise exception '브리핑 카테고리를 확인해주세요.';end if;
 for k,c in select * from jsonb_each(cfg) loop
  if k not in('reservation','onsite','cleaning','checkin') or jsonb_typeof(c->'enabled') is distinct from 'boolean' or jsonb_typeof(c->'targets') is distinct from 'array' then raise exception '브리핑 카테고리를 확인해주세요.';end if;
  if jsonb_array_length(c->'targets')>1000 then raise exception '브리핑 대상이 너무 많습니다.';end if;
  for t in select jsonb_array_elements_text(c->'targets') loop
   if t is null or not (t in('manager','reservation','onsite','cleaning','all') or exists(select from public.employees e where e.id::text=t and e.active and e.role<>'owner' and omg_private.briefing_can_receive(prop,e.property_id)) or exists(select from public.owners o where 'owner:'||o.id=t and o.active and omg_private.briefing_can_receive(prop,o.property_id))) then raise exception '권한이 없는 브리핑 수신 대상입니다.';end if;
  end loop;
 end loop;
 return cfg;
end$$;
create function omg_private.briefing_recipient_categories(prop uuid,cfg jsonb,employee uuid,owner uuid) returns text[] language sql stable set search_path='' as $$
 select coalesce(array_agg(k order by array_position(array['reservation','onsite','cleaning','checkin'],k)),'{}')
 from jsonb_each(cfg) x(k,c) where coalesce((c->>'enabled')::boolean,false) and (
 exists(select from public.employees e where e.id=employee and e.active and e.role<>'owner' and omg_private.briefing_can_receive(prop,e.property_id)
  and ((c->'targets') ? e.id::text or (e.property_id=prop and ((c->'targets') ? 'all' or (c->'targets') ?| e.duty_roles))))
 or exists(select from public.owners o where o.id=owner and o.active and omg_private.briefing_can_receive(prop,o.property_id)
  and ((o.property_id=prop and (c->'targets') ? 'manager') or (c->'targets') ? ('owner:'||o.id))))
$$;
create function omg_private.briefing_render(prop uuid,issues jsonb,categories text[],day date,error text default null) returns text language plpgsql stable set search_path='' as $$
declare k text;txt text:='';section text;row record;s jsonb;begin
 foreach k in array categories loop
  section:='';
  if k='checkin' then
   for row in select b.* from omg_private.online_bookings b where b.property_id=prop and b.arrival=day and b.status in('new','confirmed') order by b.room_name,b.guest_name,b.id loop
    s:=omg_private.pin_delivery_state(prop,row.id);
    section:=section||case when section<>'' then E'\n' else '' end||coalesce(row.room_name,'객실 미정')||' · '||coalesce(row.guest_name,'이름 미등록')||' · '||coalesce(row.arrival::text,'미정')||'~'||coalesce(row.departure::text,'미정')||' · '||coalesce(row.channel,'사이트 미확인')||' · 비번 '||
     case s->>'configured' when 'true' then '설정' when 'false' then '미설정' else '확인 필요' end||case when coalesce((s->>'active')::boolean,false) then ' / '||
     case s->>'state' when 'sent' then '발송 완료' when 'scheduled' then '발송 예정' when 'unsent' then '미발송' when 'failed' then '발송 실패' when 'resend' then '재발송 필요' when 'excluded' then '발송 제외' else '발송 확인 필요' end else '' end;
   end loop;
   if section='' then section:='오늘 체크인 예정 게스트 없음';end if;
  else
   for row in select i from jsonb_array_elements(coalesce(issues,'[]'))i where i->>'category'=k loop
    section:=section||case when section<>'' then E'\n\n' else '' end||'['||case row.i->>'urgency' when 'emergency' then '긴급·안전' when 'urgent' then '긴급' else '확인 필요' end||'] '||coalesce(row.i->>'room_number','객실 미확인')||' · '||coalesce(nullif(row.i->>'guest_name',''),'게스트')||E'\n'||coalesce(row.i->>'issue','')||E'\n상태: '||case row.i->>'status' when 'resolved' then '해결 완료' when 'needs_check' then '확인 필요' else '미해결' end||coalesce(' · '||nullif(row.i->>'action',''),'');
   end loop;
   if section='' then section:=case when error is not null then '대화 분석 실패 · 실행 로그를 확인해주세요.' else '보고할 사항 없음' end;end if;
  end if;
  txt:=txt||case when txt<>'' then E'\n\n' else '' end||'■ '||case k when 'reservation' then '예약관리' when 'onsite' then '현장관리' when 'cleaning' then '청소' else '체크인 명단 · '||day::text end||E'\n'||section;
 end loop;
 return txt;
end$$;

create or replace function omg_private.briefing_enqueue_delivery(run omg_private.briefing_runs) returns void language plpgsql set search_path='' as $$
declare cfg jsonb;local_end timestamp;due timestamptz;begin
 cfg:=coalesce(run.settings->'categories',(select categories from omg_private.briefing_settings where property_id=run.property_id));
 local_end:=run.period_end at time zone run.timezone;
 due:=case when run.mode='manual' then now() when run.settings->>'notify_kind'='time' then
 (local_end::date+(run.settings->>'notify_time')::time+case when (run.settings->>'notify_time')::time<date_trunc('minute',local_end)::time then interval '1 day' else interval '0' end) at time zone run.timezone end;
 insert into omg_private.briefing_deliveries(run_id,employee_id,due_at,categories)
 select run.id,e.id,due,omg_private.briefing_recipient_categories(run.property_id,cfg,e.id,null)
 from public.employees e where e.active and e.role<>'owner' and cardinality(omg_private.briefing_recipient_categories(run.property_id,cfg,e.id,null))>0 on conflict(run_id,employee_id) do nothing;
 insert into omg_private.briefing_deliveries(run_id,owner_id,due_at,categories)
 select run.id,o.id,coalesce(due,now()),omg_private.briefing_recipient_categories(run.property_id,cfg,null,o.id)
 from public.owners o where o.active and cardinality(omg_private.briefing_recipient_categories(run.property_id,cfg,null,o.id))>0 on conflict(run_id,owner_id) do nothing;
end$$;
revoke all on function omg_private.briefing_validate_categories(uuid,jsonb),omg_private.briefing_recipient_categories(uuid,jsonb,uuid,uuid),omg_private.briefing_render(uuid,jsonb,text[],date,text) from public,anon,authenticated;

do $migration$
declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 anchor:='  cfg:=omg_private.briefing_validate(data);';
 if strpos(def,anchor)=0 then raise exception 'Missing briefing validation hook';end if;
 def:=replace(def,anchor,anchor||$hook$
  cfg:=cfg||jsonb_build_object('categories',omg_private.briefing_validate_categories(prop,coalesce(data->'categories',(select categories from omg_private.briefing_settings where property_id=prop))));
  if action='save' then update omg_private.briefing_settings set categories=cfg->'categories' where property_id=prop;end if;
 $hook$);execute def;
 def:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 anchor:='  if items=''[]''::jsonb then';
 if strpos(def,anchor)=0 then raise exception 'Missing briefing empty hook';end if;
 def:=replace(def,anchor,$hook$  if items='[]'::jsonb or not exists(select from jsonb_each(r.settings->'categories')x where x.key<>'checkin' and (x.value->>'enabled')::boolean) and r.settings ? 'categories' then$hook$);
 anchor:=$hook$  if r.mode='manual' and r.settings ? 'notify_targets' then
   perform omg_private.briefing_enqueue_delivery(r);
  end if;$hook$;
 if strpos(def,anchor)=0 then raise exception 'Missing empty delivery hook';end if;
 def:=replace(def,anchor,$hook$
  update omg_private.briefing_runs set summary=omg_private.briefing_render(r.property_id,'[]',array(select key from jsonb_each(r.settings->'categories') where (value->>'enabled')::boolean),(now() at time zone r.timezone)::date) where id=r.id;
  perform omg_private.briefing_enqueue_delivery(r);
 $hook$);
 anchor:=$hook$  if err is null and r.mode='manual' and r.settings ? 'notify_targets' then$hook$;
 if strpos(def,anchor)=0 then raise exception 'Missing final delivery hook';end if;
 def:=replace(def,anchor,$hook$
  if r.settings ? 'categories' then
   update omg_private.briefing_runs set summary=omg_private.briefing_render(r.property_id,coalesce(data->'issues','[]'),array(select key from jsonb_each(r.settings->'categories') where (value->>'enabled')::boolean),(now() at time zone r.timezone)::date,err) where id=r.id returning * into r;
   perform omg_private.briefing_enqueue_delivery(r);
   return jsonb_build_object('ok',true,'id',r.id);
  end if;
 $hook$||anchor);execute def;
 def:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 anchor:='finished_at=now() where id=r.id;return jsonb_build_object(''skip'',true);';
 def:=replace(def,anchor,'finished_at=now() where id=r.id; if r.settings ? ''categories'' and coalesce((r.settings->''categories''->''checkin''->>''enabled'')::boolean,false) then perform omg_private.briefing_enqueue_delivery(r);end if;return jsonb_build_object(''skip'',true);');
 execute def;
 def:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='r.mode,r.summary,r.property_id';
 if strpos(def,anchor)=0 then raise exception 'Missing recipient summary hook';end if;
 def:=replace(def,anchor,$hook$r.mode,case when d.categories is null then r.summary else omg_private.briefing_render(r.property_id,r.issues,array(select k from unnest(d.categories)k where k=any(omg_private.briefing_recipient_categories(r.property_id,case when r.mode='manual' then r.settings->'categories' else s.categories end,d.employee_id,d.owner_id))),(now() at time zone r.timezone)::date,r.error) end as summary,r.property_id$hook$);
 execute def;
end$migration$;

commit;
