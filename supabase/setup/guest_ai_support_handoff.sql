alter table omg_private.ai_settings add column if not exists support_policy text not null default '';
-- Guest AI handoff: onsite alert modes, durable bot history, room deep links.
CREATE OR REPLACE FUNCTION public.get_guest_chat_dispatch(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;alert omg_private.ai_alerts%rowtype;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;

 -- AI handles ordinary questions silently; escalation has its own durable event.
 if ev.event_kind='message' and exists(select 1 from omg_private.ai_jobs where message_id=ev.message_id and status in('pending','leased','completed','handoff')) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb);end if;
 select * into alert from omg_private.ai_alerts where event_id=ev.id;

 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
  coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
  select distinct on(c.topic)c.topic,c.alert_mode,c.valid_until from(
   select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,s->>'alert_mode' alert_mode,
    ((extract(epoch from least(ev.created_at+interval '5 minutes',
     (case when nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time' then (local.t::date+1)::timestamp
      when (s->>'start_time')::time>(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time then (local.t::date+1)+(s->>'end_time')::time
      else local.t::date+(s->>'end_time')::time end) at time zone p.timezone))*1000)::bigint)::text valid_until,
    case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end strength
   from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
   cross join lateral jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone p.timezone t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.property_id=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and omg_private.guest_can_access(n.home_property_id,r.property_id)
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   and (exists(select 1 from public.work_sessions ws join public.employees e on e.id=ws.employee_id where 'employee:'||e.id=n.actor_key and e.active and ws.status='working' and ws.token_expires_at>now())
    or exists(select 1 from public.owner_sessions os join public.owners o on o.id=os.owner_id where 'owner:'||o.id=n.actor_key and o.active and os.token_expires_at>now()))
  )c order by c.topic,c.strength desc,c.valid_until desc
 )x;
 if alert.event_id is not null then
  -- Same schedule-derived modes as onsite guest chat; retain owner/duty fallback.
  select coalesce(jsonb_agg(distinct x.topic),'[]') into topics from (
   select value as topic from jsonb_array_elements_text(topics)
   union select 'property_'||p.management_number||'_owner_'||o.id from public.owners o join public.properties p on p.id=o.property_id where o.property_id=r.property_id and o.active
   union select 'property_'||p.management_number||'_employee_'||e.id from public.work_sessions w join public.employees e on e.id=w.employee_id join public.properties p on p.id=w.property_id where w.property_id=r.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now()
  )x;
  select coalesce(jsonb_object_agg(t,case when alert.urgent then 'urgent' else coalesce(modes->>t,'urgent') end),'{}') into modes from jsonb_array_elements_text(topics)t;
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_modes',modes,'recipient_deadlines',deadlines,'message_type','guest_chat','valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,'priority',case when alert.urgent then 'urgent' else 'normal' end,'sender_label',case when alert.urgent then '긴급 AI 지원요청 · ' else 'AI 지원요청 · ' end||r.guest_name||' · '||coalesce(r.room_number,'객실 미정'),'message',alert.reason||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=alert.message_id),''));
 end if;
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat',
  'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
  'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label',r.guest_name,
  'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.') end);
end$function$

;

-- Store a single bot message per durable AI event. No independent push is sent.
create or replace function omg_private.ai_record_notice(p_event uuid) returns void
language plpgsql security definer set search_path='' as $$
declare a omg_private.ai_alerts%rowtype;r public.guest_chat_rooms%rowtype;mid uuid;delivery jsonb;begin
 select * into a from omg_private.ai_alerts where event_id=p_event;
 if not found then return;end if;
 select * into r from public.guest_chat_rooms where id=a.room_id;
 select id into mid from public.property_messages where source='guest_ai' and external_message_id=p_event::text;
 if mid is not null then return;end if;
 delivery:=public.get_guest_chat_dispatch(p_event);
 insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
 select p.business_id,p.id,'system',
  '[OMS-GUEST-CHAT:'||r.id||']'||E'\n'||case when a.urgent then '긴급 AI 지원요청' else 'AI 메시지 지원요청' end||E'\n'||left(r.guest_name,120)||' · '||left(coalesce(r.room_number,'객실 미정'),100)||E'\n게스트 문의가 왔습니다. 직원 확인이 필요합니다.'||E'\n'||left(coalesce(a.reason,''),500)||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=a.message_id),''),
  'normal','general','guest_ai',p_event::text from public.properties p where p.id=r.property_id returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)
 select mid,'owner:'||o.id,'owner',o.id,null from public.owners o join public.properties p on p.id=o.property_id
 where o.active and delivery->'recipient_topics' ? ('property_'||p.management_number||'_owner_'||o.id)
 union all select mid,'employee:'||e.id,'staff',null,e.id from public.employees e join public.properties p on p.id=e.property_id
 where e.active and delivery->'recipient_topics' ? ('property_'||p.management_number||'_employee_'||e.id);
end$$;
revoke all on function omg_private.ai_record_notice(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION omg_private.ai_alert(p_room uuid, p_message uuid, p_urgent boolean, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev uuid;begin
 perform pg_advisory_xact_lock(hashtextextended(p_room::text,71));
 update public.guest_chat_rooms set ai_handoff=true,ai_paused=ai_paused or p_urgent,updated_at=now() where id=p_room;
 select event_id into ev from omg_private.ai_alerts where room_id=p_room and message_id is not distinct from p_message and urgent=p_urgent and created_at>now()-interval '60 seconds' order by created_at desc limit 1;
 if ev is null then
  insert into public.guest_chat_events(room_id,event_kind)values(p_room,case when p_urgent then 'ai_urgent' else 'ai_handoff' end) returning id into ev;
  insert into omg_private.ai_alerts(event_id,room_id,message_id,urgent,reason)values(ev,p_room,p_message,p_urgent,left(p_reason,500));
 end if;
 perform omg_private.ai_record_notice(ev);
 return ev;
end$function$

;

do $patch$
declare f text;begin
 f:=pg_get_functiondef('omg_private.ai_claim()'::regprocedure);
 if strpos(f,'''support_policy'',s.support_policy')=0 then
  if strpos(f,'''id'',j.id,''lease_id'',j.lease_id')=0 then raise exception 'AI claim signature changed';end if;
  execute replace(f,'''id'',j.id,''lease_id'',j.lease_id','''id'',j.id,''support_policy'',s.support_policy,''lease_id'',j.lease_id');
 end if;
 f:=pg_get_functiondef('public.list_notification_bot_messages(uuid,timestamptz,uuid)'::regprocedure);
 if strpos(f,'''guest_chat_room_id''')=0 then
  execute replace(replace(f,
   '''message'',m.message,''priority'',m.priority','''message'',m.message,''guest_chat_room_id'',case when m.source=''guest_ai'' then substring(m.message from ''^\[OMS-GUEST-CHAT:([0-9a-f-]{36})\]'') else null end,''priority'',m.priority'),
   'when m.sender_type=''system'' then ''근태관리''','when m.source=''guest_ai'' then ''AI 지원요청'' when m.sender_type=''system'' then ''근태관리''');
 end if;
end$patch$;
