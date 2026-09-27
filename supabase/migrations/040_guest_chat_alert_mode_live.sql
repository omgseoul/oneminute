-- Lightweight live deployment for per-account guest chat alert modes.
begin;
alter table public.guest_chat_alert_preferences add column if not exists alert_mode text not null default 'urgent'
 check(alert_mode in ('normal','urgent'));

create or replace function public.save_guest_chat_alert_mode(p_access_token uuid,p_actor_key text,p_alert_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare home uuid;
begin
 if p_alert_mode not in ('normal','urgent') then raise exception '알림 방식을 선택해주세요.';end if;
 select o.property_id into home from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if home is null then raise exception '관리자 로그인이 필요합니다.';end if;
 if not exists(select 1 from public.employees where 'employee:'||id=p_actor_key and property_id=home and active)
 and not exists(select 1 from public.owners where 'owner:'||id=p_actor_key and property_id=home and active)
 then raise exception '자기 지점 계정만 설정할 수 있습니다.';end if;
 update public.guest_chat_alert_preferences set alert_mode=p_alert_mode,updated_at=now()
 where actor_key=p_actor_key and home_property_id=home;
 if not found then raise exception '게스트 메세지 알림 설정을 먼저 저장해주세요.';end if;
 return jsonb_build_object('ok',true,'alert_mode',p_alert_mode);
end$$;
revoke all on function public.save_guest_chat_alert_mode(uuid,text,text) from public;
grant execute on function public.save_guest_chat_alert_mode(uuid,text,text) to anon,authenticated;

create or replace function public.get_guest_chat_dispatch(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;
 select coalesce(jsonb_agg(distinct x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
 coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
 select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,n.alert_mode,
 ((extract(epoch from least(ev.created_at+interval '5 minutes',
 (case when n.start_time is null or n.start_time=n.end_time then (local.t::date+1)::timestamp
 when n.start_time>n.end_time and local.t::time>=n.start_time then (local.t::date+1)+n.end_time
 else local.t::date+n.end_time end) at time zone p.timezone))*1000)::bigint)::text valid_until
 from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
 cross join lateral(select now() at time zone p.timezone t) local
 where n.enabled and r.property_id=any(n.property_ids) and omg_private.guest_can_access(n.home_property_id,r.property_id)
 and (case when n.start_time is not null and n.end_time<n.start_time and local.t::time<n.end_time then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)=any(n.days)
 and (n.start_time is null or n.start_time=n.end_time or (n.start_time<n.end_time and local.t::time>=n.start_time and local.t::time<n.end_time) or (n.start_time>n.end_time and (local.t::time>=n.start_time or local.t::time<n.end_time)))
 and (exists(select 1 from public.work_sessions s join public.employees e on e.id=s.employee_id where 'employee:'||e.id=n.actor_key and e.active and s.status='working' and s.token_expires_at>now())
 or exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id where 'owner:'||o.id=n.actor_key and o.active and s.token_expires_at>now()))
 )x;
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat',
 'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
 'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label','현장 게스트',
 'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else '현장 게스트에게 새 메시지가 왔습니다. 채팅방을 확인해주세요.' end);
end$$;
commit;
