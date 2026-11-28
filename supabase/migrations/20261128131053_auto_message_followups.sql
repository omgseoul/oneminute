begin;
alter table omg_private.auto_message_rules add column calendar_pin_sent boolean not null default false;
-- Existing password rules retain tracking and opt into the requested calendar marker.
update omg_private.auto_message_rules set calendar_pin_sent=pin_notice where messages::text like '%{{비밀번호}}%';
update omg_private.auto_message_rules set pin_notice=false where messages::text not like '%{{비밀번호}}%';
alter table omg_private.pin_delivery_events add column calendar_pin_sent boolean not null default false;

create table omg_private.auto_message_followups(
 delivery_id uuid primary key references omg_private.auto_message_deliveries(id) on delete cascade,
 property_id uuid not null references public.properties(id), booking_id bigint not null,
 retry_count integer not null, status text not null default 'open' check(status in('open','planned','external','ignored','sent')),
 pin_notice boolean not null, calendar_pin_sent boolean not null, booking_signature text,
 actor text, resolved_at timestamptz, next_notice_at timestamptz not null default now()+interval '1 hour',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index auto_message_followups_due on omg_private.auto_message_followups(next_notice_at) where status in('open','planned');
create index auto_message_followups_booking on omg_private.auto_message_followups(property_id,booking_id,updated_at desc);
create table omg_private.auto_message_reminders(
 id uuid primary key default gen_random_uuid(), delivery_id uuid not null references omg_private.auto_message_followups(delivery_id) on delete cascade,
 message_id uuid not null references public.property_messages(id), retry_count integer not null, created_at timestamptz not null default now(), pushed_at timestamptz);
create index auto_message_reminders_push on omg_private.auto_message_reminders(created_at) where pushed_at is null;
create unique index auto_message_reminders_message on omg_private.auto_message_reminders(message_id);
create index if not exists auto_message_notices_message on omg_private.auto_message_notices(message_id);
create table omg_private.pin_calendar_outbox(
 property_id uuid not null references public.properties(id), booking_id bigint not null,
 event_id uuid not null references omg_private.pin_delivery_events(id),
 status text not null default 'pending' check(status in('pending','sending','done','obsolete')),
 lease uuid, leased_until timestamptz, attempts integer not null default 0, next_at timestamptz not null default now(),
 error text, updated_at timestamptz not null default now(), primary key(property_id,booking_id));
create index pin_calendar_outbox_due on omg_private.pin_calendar_outbox(next_at) where status in('pending','sending');
alter table omg_private.auto_message_followups enable row level security;
alter table omg_private.auto_message_reminders enable row level security;
alter table omg_private.pin_calendar_outbox enable row level security;
revoke all on omg_private.auto_message_followups,omg_private.auto_message_reminders,omg_private.pin_calendar_outbox from public,anon,authenticated;

-- Staff currently on duty receive each reminder; a new shift joins the next reminder.
create function omg_private.auto_message_followup_recipients(prop uuid,mid uuid) returns void language sql set search_path='' as $$
 insert into public.property_message_recipients(message_id,recipient_type,employee_id,recipient_key)
 select mid,'staff',e.id,'employee:'||e.id from public.employees e
 where e.property_id=prop and e.active and exists(select 1 from public.work_sessions w where w.employee_id=e.id and w.property_id=prop
  and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now())
 and not exists(select 1 from public.property_message_recipients r where r.message_id=mid and r.employee_id=e.id)
$$;

-- Keep existing notice bodies and per-attempt deduplication. Only genuine failed or
-- uncertain sends enter the follow-up queue; historical scheduling exclusions do not.
alter function omg_private.auto_message_notice(uuid,text) rename to auto_message_notice_before_followups;
create function omg_private.auto_message_notice(p_delivery uuid,p_kind text) returns void language plpgsql security definer set search_path='' as $$
declare d omg_private.auto_message_deliveries%rowtype;r omg_private.auto_message_rules%rowtype;mid uuid;begin
 perform omg_private.auto_message_notice_before_followups(p_delivery,p_kind);
 select * into d from omg_private.auto_message_deliveries where id=p_delivery;
 if p_kind<>'terminal' or d.status not in('failed','uncertain') then return;end if;
 select * into r from omg_private.auto_message_rules where id=d.rule_id;
 insert into omg_private.auto_message_followups(delivery_id,property_id,booking_id,retry_count,pin_notice,calendar_pin_sent,booking_signature)
 values(d.id,d.property_id,d.booking_id,d.retry_count,r.pin_notice or r.calendar_pin_sent,r.calendar_pin_sent,omg_private.pin_booking_signature(d.property_id,d.booking_id))
 on conflict(delivery_id) do update set retry_count=excluded.retry_count,status='open',pin_notice=excluded.pin_notice,calendar_pin_sent=excluded.calendar_pin_sent,
 booking_signature=excluded.booking_signature,actor=null,resolved_at=null,next_notice_at=now()+interval '1 hour',updated_at=now()
 where auto_message_followups.retry_count<>excluded.retry_count;
 select message_id into mid from omg_private.auto_message_notices where delivery_id=d.id and retry_count=d.retry_count and kind='terminal';
 if mid is not null then perform omg_private.auto_message_followup_recipients(d.property_id,mid);end if;
end$$;

create function omg_private.auto_message_followup_scan() returns void language plpgsql security definer set search_path='' as $$
declare f omg_private.auto_message_followups%rowtype;d omg_private.auto_message_deliveries%rowtype;mid uuid;body text;prop public.properties%rowtype;begin
 for f in select * from omg_private.auto_message_followups where status in('open','planned') and next_notice_at<=now() order by next_notice_at for update skip locked limit 100 loop
  select * into d from omg_private.auto_message_deliveries where id=f.delivery_id;
  if d.status in('waiting','preparing','sending') then continue;end if;
  select m.message into body from omg_private.auto_message_notices n join public.property_messages m on m.id=n.message_id
   where n.delivery_id=f.delivery_id and n.kind='terminal' order by n.created_at desc limit 1;
  select * into prop from public.properties where id=f.property_id;
  insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
   values(prop.business_id,prop.id,'system',left(coalesce(body,'자동메시지 발송 상태 확인 필요'),1800)||E'\n미해결 알림 · 해결 전까지 1시간마다 알립니다.','normal','general','auto_message',gen_random_uuid()::text) returning id into mid;
  insert into omg_private.auto_message_reminders(delivery_id,message_id,retry_count) values(f.delivery_id,mid,f.retry_count);
  insert into public.property_message_recipients(message_id,recipient_type,owner_id,recipient_key)
   select mid,'owner',o.id,'owner:'||o.id from public.owners o where omg_private.auto_message_owner_eligible(f.property_id,o.id);
  perform omg_private.auto_message_followup_recipients(f.property_id,mid);
  update omg_private.auto_message_followups set next_notice_at=now()+interval '1 hour' where delivery_id=f.delivery_id;
 end loop;
end$$;

-- Snapshot calendar intent at preparation, and enforce template gating on the server.
do $patch$ declare f text;old text;begin
 f:=pg_get_functiondef('omg_private.auto_message_owner(uuid,text,jsonb)'::regprocedure);
 old:=$n$update omg_private.auto_message_rules set pin_notice=coalesce((p_data->>'pin_notice')::boolean,false) or messages::text like '%{{비밀번호}}%' where id=rid;$n$;
 if strpos(f,old)=0 then raise exception 'Missing password rule hook';end if;
 execute replace(f,old,$n$update omg_private.auto_message_rules set pin_notice=coalesce((p_data->>'pin_notice')::boolean,true) and messages::text like '%{{비밀번호}}%',
 calendar_pin_sent=coalesce((p_data->>'calendar_pin_sent')::boolean,false) and messages::text like '%{{비밀번호}}%' where id=rid;$n$);
 f:=pg_get_functiondef('omg_private.auto_message_internal(text,jsonb)'::regprocedure);
 old:='update omg_private.auto_message_deliveries set pin_event_id=j.pin_event_id where id=j.id;';
 if strpos(f,old)=0 then raise exception 'Missing password evidence hook';end if;
 execute replace(f,old,old||' update omg_private.pin_delivery_events set calendar_pin_sent=r.calendar_pin_sent where id=j.pin_event_id;');
 f:=pg_get_functiondef('omg_private.auto_message_scan()'::regprocedure);
 old:='begin';if strpos(f,old)=0 then raise exception 'Missing scan hook';end if;
 -- Run reminders before scheduling; both the cron and worker share this locked queue.
 execute overlay(f placing 'begin perform omg_private.auto_message_followup_scan();' from strpos(f,old) for length(old));
end$patch$;

create function omg_private.pin_send_resolved() returns trigger language plpgsql set search_path='' as $$
begin
 if new.status not in('sent','external') or (tg_op='UPDATE' and old.status=new.status) then return new;end if;
 if new.booking_signature is distinct from omg_private.pin_booking_signature(new.property_id,new.booking_id) then return new;end if;
 if new.fingerprint is distinct from (select fingerprint from omg_private.booking_pin_state where property_id=new.property_id and booking_id=new.booking_id) then return new;end if;
 update omg_private.auto_message_followups set status=case when new.status='external' then 'external' else 'sent' end,
  actor=new.actor,resolved_at=now(),updated_at=now()
  where property_id=new.property_id and booking_id=new.booking_id and pin_notice and status in('open','planned') and booking_signature=new.booking_signature;
 if new.calendar_pin_sent or (new.via<>'auto' and exists(select 1 from omg_private.auto_message_rules r where r.property_id=new.property_id and r.enabled and r.calendar_pin_sent)) then
  insert into omg_private.pin_calendar_outbox(property_id,booking_id,event_id) values(new.property_id,new.booking_id,new.id)
  on conflict(property_id,booking_id) do update set event_id=excluded.event_id,status='pending',lease=null,leased_until=null,attempts=0,error=null,next_at=now(),updated_at=now();
 end if;
 return new;
end$$;
create trigger pin_send_resolved after insert or update of status on omg_private.pin_delivery_events for each row execute function omg_private.pin_send_resolved();
create function omg_private.auto_message_followup_sent() returns trigger language plpgsql set search_path='' as $$begin
 if new.status='sent' then update omg_private.auto_message_followups set status='sent',resolved_at=now(),updated_at=now() where delivery_id=new.id and status in('open','planned');end if;return new;
end$$;
create trigger auto_message_followup_sent after update of status on omg_private.auto_message_deliveries for each row execute function omg_private.auto_message_followup_sent();

-- Actions require a current authenticated actor and access to this specific alert.
create function public.auto_message_followup(p_token uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_token);f omg_private.auto_message_followups%rowtype;d omg_private.auto_message_deliveries%rowtype;
 act text:=p_data->>'action';fp text;ev uuid;begin
 if a is null then raise exception '다시 로그인해주세요.';end if;
 -- Lock delivery first, consistently with worker settlement, to avoid deadlocks.
 select * into d from omg_private.auto_message_deliveries where id=(p_data->>'delivery_id')::uuid for update;
 select * into f from omg_private.auto_message_followups where delivery_id=d.id for update;
 if f.delivery_id is null then raise exception '처리할 발송실패 알림을 찾지 못했습니다.';end if;
 if not ((a->>'kind'='owner' and omg_private.auto_message_owner_eligible(f.property_id,(a->>'id')::uuid)) or
  (a->>'kind'='staff' and (a->>'property_id')::uuid=f.property_id and exists(
   select 1 from public.property_message_recipients r where r.employee_id=(a->>'id')::uuid and
    (exists(select 1 from omg_private.auto_message_notices n where n.message_id=r.message_id and n.delivery_id=f.delivery_id)
     or exists(select 1 from omg_private.auto_message_reminders n where n.message_id=r.message_id and n.delivery_id=f.delivery_id))))) then raise exception '이 알림의 처리 권한이 없습니다.';end if;
 if act='state' then return jsonb_build_object('ok',true,'property_id',f.property_id,'booking_id',f.booking_id,'pin_notice',f.pin_notice,'status',f.status,'retry_count',f.retry_count);end if;
 if act not in('planned','ignored','external') or act is null then raise exception '처리 방법을 선택해주세요.';end if;
 if f.retry_count is distinct from (p_data->>'retry_count')::integer then raise exception '새 발송 시도가 있습니다. 최신 알림을 확인해주세요.';end if;
 if f.status in('sent','external','ignored') then return jsonb_build_object('ok',true,'status',f.status,'already',true);end if;
 if d.status in('waiting','preparing','sending') then raise exception '재전송이 진행 중입니다. 결과를 확인한 뒤 처리해주세요.';end if;
 if act='external' and f.pin_notice then
  if f.booking_signature is distinct from omg_private.pin_booking_signature(f.property_id,f.booking_id) then raise exception '예약 객실 또는 일정이 변경되었습니다. 예약정보에서 전달한 비밀번호를 다시 확인해주세요.';end if;
  fp:=omg_private.pin_observe(f.property_id,f.booking_id,p_data->>'pin');
  if fp is null then raise exception '전달한 비밀번호를 확인할 수 없습니다. 예약정보를 확인해주세요.';end if;
  insert into omg_private.pin_delivery_events(id,property_id,booking_id,fingerprint,booking_signature,status,via,title,actor,calendar_pin_sent)
   values(gen_random_uuid(),f.property_id,f.booking_id,fp,f.booking_signature,'external','external','다른 방법으로 전송하였음',a->>'key',f.calendar_pin_sent) returning id into ev;
 end if;
 update omg_private.auto_message_followups set status=act,actor=a->>'key',resolved_at=case when act='planned' then null else now() end,updated_at=now() where delivery_id=f.delivery_id;
 return jsonb_build_object('ok',true,'status',act,'pin_delivery',omg_private.pin_delivery_state(f.property_id,f.booking_id));
end$$;

-- The calendar write is an independent outbox; its failure cannot resend a guest message.
create function public.pin_calendar_internal(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare j omg_private.pin_calendar_outbox%rowtype;e omg_private.pin_delivery_events%rowtype;begin
 if p_action='claim' then
  select * into j from omg_private.pin_calendar_outbox where (status='pending' and next_at<=now()) or (status='sending' and leased_until<now()) order by next_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  update omg_private.pin_calendar_outbox set status='sending',lease=gen_random_uuid(),leased_until=now()+interval '2 minutes',attempts=attempts+1 where property_id=j.property_id and booking_id=j.booking_id returning * into j;
  return to_jsonb(j);
 end if;
 select * into j from omg_private.pin_calendar_outbox where property_id=(p_data->>'property_id')::uuid and booking_id=(p_data->>'booking_id')::bigint for update;
 if not found or j.lease is null or j.lease is distinct from (p_data->>'lease')::uuid or j.status<>'sending' or j.leased_until<now() then return jsonb_build_object('skip',true);end if;
 if p_action='verify' then
  select * into e from omg_private.pin_delivery_events where id=j.event_id;
  if not found or e.status not in('sent','external') or e.booking_signature is distinct from omg_private.pin_booking_signature(j.property_id,j.booking_id)
    or e.fingerprint is distinct from (select fingerprint from omg_private.booking_pin_state where property_id=j.property_id and booking_id=j.booking_id) then
   update omg_private.pin_calendar_outbox set status='obsolete',lease=null where property_id=j.property_id and booking_id=j.booking_id;
   return jsonb_build_object('skip',true);
  end if;
  return jsonb_build_object('ok',true);
 elsif p_action='finish' then
  update omg_private.pin_calendar_outbox set status=case when p_data->>'status'='done' then 'done' else 'pending' end,
   next_at=now()+interval '1 hour',error=case when p_data->>'status'='done' then null else 'Beds24 캘린더 표시 재시도 대기' end,lease=null,leased_until=null,updated_at=now()
   where property_id=j.property_id and booking_id=j.booking_id;
  return jsonb_build_object('ok',true);
 end if;raise exception '지원하지 않는 요청입니다.';
end$$;

create or replace function omg_private.auto_message_notice_context(p_message uuid,p_property uuid) returns jsonb language sql stable set search_path='' as $$
 with notice as (select n.delivery_id,n.retry_count from omg_private.auto_message_notices n where n.message_id=p_message and n.kind='terminal' union all select n.delivery_id,n.retry_count from omg_private.auto_message_reminders n where n.message_id=p_message)
 select jsonb_build_object('delivery_id',d.id,'retry_count',n.retry_count,'status',d.status,'can_retry',d.status='failed' and n.retry_count=d.retry_count and r.enabled and coalesce(f.status,'open') in('open','planned'),
 'arrival',b.arrival,'departure',b.departure,'followup',f.status,'pin_notice',f.pin_notice,'next_notice_at',f.next_notice_at)
 from notice n join omg_private.auto_message_deliveries d on d.id=n.delivery_id join omg_private.auto_message_rules r on r.id=d.rule_id
 left join omg_private.auto_message_followups f on f.delivery_id=d.id
 left join omg_private.online_bookings b on b.property_id=d.property_id and b.id=d.booking_id
 where d.property_id=p_property
$$;

-- Existing, already authorized message readers expose action metadata to staff too.
do $patch$ declare f text;sig text;old text;begin
 old:=$n$when v_is_owner and m.source='auto_message'$n$;
 foreach sig in array array['public.list_property_messages(uuid)','public.list_notification_bot_messages(uuid,timestamptz,uuid)'] loop
  f:=pg_get_functiondef(sig::regprocedure);if strpos(f,old)=0 then raise exception 'Missing alert reader hook %',sig;end if;
  execute replace(f,old,$n$when m.source='auto_message'$n$);
 end loop;
 f:=pg_get_functiondef('omg_private.auto_message_internal(text,jsonb)'::regprocedure);
 old:='from(select id,message_id from omg_private.auto_message_notices where pushed_at is null and message_id is not null order by created_at limit 20)x';
 if strpos(f,old)=0 then raise exception 'Missing notice push queue';end if;
 f:=replace(f,old,'from(select id,message_id from (select id,message_id,created_at from omg_private.auto_message_notices where pushed_at is null and message_id is not null union all select id,message_id,created_at from omg_private.auto_message_reminders where pushed_at is null) q order by created_at limit 20)x');
 old:=$n$if p_action='pushed' then$n$;
 f:=replace(f,old,old||$n$ update omg_private.auto_message_reminders set pushed_at=now() where id=(p_data->>'id')::uuid;$n$);execute f;
end$patch$;

create or replace function omg_private.auto_message_push_dispatch(p_message_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.property_messages%rowtype;mode text;name text;modes jsonb;topics jsonb;begin
 select * into m from public.property_messages where id=p_message_id and source='auto_message';if not found then return jsonb_build_object('ok',false);end if;
 -- A queued reminder may have been resolved before push dispatch.
 if exists(select 1 from omg_private.auto_message_followups f where f.status not in('open','planned') and (exists(select 1 from omg_private.auto_message_reminders n where n.delivery_id=f.delivery_id and n.message_id=m.id) or exists(select 1 from omg_private.auto_message_notices n where n.delivery_id=f.delivery_id and n.message_id=m.id and n.kind='terminal'))) then
  return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'recipient_topics','[]'::jsonb,'recipient_modes','{}'::jsonb);end if;
 select coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림') into mode,name from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=m.property_id;
 select coalesce(jsonb_object_agg(topic,mode),'{}') into modes from (
  select 'property_'||p.management_number||'_owner_'||o.id topic from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
   where r.message_id=m.id and omg_private.auto_message_owner_eligible(m.property_id,o.id)
  union select 'property_'||p.management_number||'_employee_'||e.id from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
   where r.message_id=m.id and e.property_id=m.property_id and e.active and exists(select 1 from public.work_sessions w where w.employee_id=e.id and w.property_id=m.property_id and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now())
 )x;
 select coalesce(jsonb_agg(topic),'[]') into topics from jsonb_object_keys(modes)x(topic);
 return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'sender_label',name||' · 자동메시지','recipient_topics',topics,'recipient_modes',modes);
end$$;

alter function omg_private.pin_delivery_state(uuid,bigint,boolean) rename to pin_delivery_state_before_followups;
create function omg_private.pin_delivery_state(prop uuid,bid bigint,p_history boolean default false) returns jsonb language plpgsql stable set search_path='' as $$
declare v jsonb:=omg_private.pin_delivery_state_before_followups(prop,bid,p_history);f omg_private.auto_message_followups%rowtype;begin
 select * into f from omg_private.auto_message_followups where property_id=prop and booking_id=bid and pin_notice order by updated_at desc limit 1;
 if f.status='ignored' and v->>'state'<>'sent' and f.booking_signature=omg_private.pin_booking_signature(prop,bid) then v:=v||jsonb_build_object('state','excluded','resolution','ignored');end if;
 return v;
end$$;
revoke all on function omg_private.pin_delivery_state_before_followups(uuid,bigint,boolean),omg_private.pin_delivery_state(uuid,bigint,boolean),omg_private.auto_message_followup_recipients(uuid,uuid),omg_private.auto_message_notice_before_followups(uuid,text),omg_private.auto_message_notice(uuid,text),omg_private.auto_message_followup_scan(),omg_private.pin_send_resolved(),omg_private.auto_message_followup_sent(),public.auto_message_followup(uuid,jsonb),public.pin_calendar_internal(text,jsonb) from public,anon,authenticated;
grant execute on function public.auto_message_followup(uuid,jsonb),public.pin_calendar_internal(text,jsonb) to service_role;
-- Bring active, existing failures into the same queue without replaying old notices.
do $seed$ declare d record;begin
 for d in select x.id from omg_private.auto_message_deliveries x join omg_private.online_bookings b on b.property_id=x.property_id and b.id=x.booking_id join public.properties p on p.id=x.property_id
 where x.status in('failed','uncertain') and b.status in('new','confirmed') and b.departure>=(now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date
 and not exists(select 1 from omg_private.pin_delivery_events e where e.property_id=x.property_id and e.booking_id=x.booking_id and e.status in('sent','external') and e.booking_signature=omg_private.pin_booking_signature(x.property_id,x.booking_id) and e.fingerprint=(select fingerprint from omg_private.booking_pin_state where property_id=x.property_id and booking_id=x.booking_id)) loop
  perform omg_private.auto_message_notice(d.id,'terminal');
 end loop;
end$seed$;
commit;
