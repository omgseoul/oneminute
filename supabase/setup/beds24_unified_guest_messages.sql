-- One guest inbox with the existing custom-session and message-sharing boundaries.
-- No new session, no change to QR rooms, message bodies, delivery or acknowledgment.
begin;
create or replace function omg_private.guest_message_inbox(p_access_token uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_access_token);home uuid;prop uuid;lo date;hi date;result jsonb;begin
 if a is null then raise exception '직원 로그인이 필요합니다.';end if;
 home:=(a->>'property_id')::uuid;prop:=nullif(p_data->>'property_id','')::uuid;
 if prop is not null and not coalesce(omg_private.guest_can_access(home,prop),false) then raise exception '이 지점의 메시지 권한이 없습니다.';end if;
 lo:=nullif(p_data->>'message_from','')::date;hi:=nullif(p_data->>'message_to','')::date;
 if hi<lo then raise exception '조회 기간을 확인해주세요.';end if;
 select coalesce(jsonb_agg(to_jsonb(page) order by page.sent_at desc,page.booking_id),'[]') into result from (select * from (
  select 'qr' kind,r.id::text booking_id,r.property_id,p.name property_name,r.guest_name,r.room_number room_name,r.check_in arrival,r.check_out departure,'qr' status,
   m.id::text message_id,m.seq,case when m.sender_kind='guest' then 'guest' else 'host' end source,m.created_at sent_at,
   case when m.body='' and m.asset_id is not null then '사진' else m.body end preview,
   (select count(*) from public.guest_chat_messages u where u.room_id=r.id and u.sender_kind='guest' and u.seq>coalesce((select gr.last_seq from public.guest_chat_reads gr where gr.room_id=r.id and gr.actor_key=a->>'key'),0)) unread,
   (select coalesce(max(g.seq) filter(where g.sender_kind in('staff','owner','ai')),0)>coalesce(max(g.seq) filter(where g.sender_kind='guest'),0) from public.guest_chat_messages g where g.room_id=r.id) replied
  from public.guest_chat_rooms r join public.properties p on p.id=r.property_id
  cross join lateral(select g.* from public.guest_chat_messages g where g.room_id=r.id and g.sender_kind<>'system'
   and (coalesce(p_data->>'direction','all')='all' or (p_data->>'direction'='guest' and g.sender_kind='guest') or (p_data->>'direction'='host' and g.sender_kind in('staff','owner','ai')))
   order by g.seq desc limit 1)m
  where coalesce(omg_private.guest_can_access(home,r.property_id),false) and (prop is null or r.property_id=prop)
   and (lo is null or (m.created_at at time zone p.timezone)::date>=lo) and (hi is null or (m.created_at at time zone p.timezone)::date<=hi)
   and (not(p_data?'stay_types') or case
     when r.check_in=(now() at time zone p.timezone)::date then 'checkin'
     when r.check_out=(now() at time zone p.timezone)::date then 'checkout'
     when r.check_in<(now() at time zone p.timezone)::date and r.check_out>(now() at time zone p.timezone)::date then 'staying' else 'other' end in(select jsonb_array_elements_text(p_data->'stay_types')))
 )x where (not coalesce((p_data->>'unread_only')::boolean,false) or x.unread>0) and (not coalesce((p_data->>'unreplied_only')::boolean,false) or not x.replied) order by x.sent_at desc,x.booking_id limit 300 offset greatest(0,least(coalesce((p_data->>'offset')::int,0),15000)))page;
 return jsonb_build_object('ok',true,'threads',result,'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name)),'[]') from public.properties p where omg_private.guest_can_access(home,p.id)));
end$$;
create or replace function public.guest_message_inbox(p_access_token uuid,p_data jsonb default '{}')returns jsonb language sql security invoker set search_path='' as $$select omg_private.guest_message_inbox(p_access_token,p_data)$$;
revoke all on function public.guest_message_inbox(uuid,jsonb),omg_private.guest_message_inbox(uuid,jsonb) from public;
grant execute on function public.guest_message_inbox(uuid,jsonb),omg_private.guest_message_inbox(uuid,jsonb) to anon,authenticated,service_role;

create or replace function omg_private.guest_message_unread(p_access_token uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_access_token);home uuid;n bigint;begin
 if a is null then raise exception '직원 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 select count(*) into n from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where m.sender_kind='guest' and omg_private.guest_can_access(home,r.property_id) and m.seq>coalesce((select g.last_seq from public.guest_chat_reads g where g.room_id=r.id and g.actor_key=a->>'key'),0);
 select n+count(*) into n from omg_private.online_messages m where m.source='guest' and m.read_at is null and omg_private.guest_can_access(home,m.property_id);
 return jsonb_build_object('ok',true,'unread',n,'messenger_unread',(select count(*) from public.property_message_recipients r join public.property_messages m on m.id=r.message_id where r.recipient_key=a->>'key' and r.read_at is null and coalesce(m.source,'')<>'beds24' and coalesce(m.message_type,'')<>'guest_chat'));
end$$;
create or replace function public.guest_message_unread(p_access_token uuid)returns jsonb language sql security invoker set search_path='' as $$select omg_private.guest_message_unread(p_access_token)$$;
revoke all on function public.guest_message_unread(uuid),omg_private.guest_message_unread(uuid) from public;
grant execute on function public.guest_message_unread(uuid),omg_private.guest_message_unread(uuid) to anon,authenticated,service_role;

-- Extend only the message/operational read paths. Keep connection, key, billing and notification settings owner-only.
do $patch$
declare f text;old text;replacement text;begin
 f:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,'unified_guest_access_v1')=0 then
 old:=$old$if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;$old$;
 if strpos(f,old)=0 then raise exception 'online actor guard changed';end if;
 f:=replace(f,old,$new$if a is null or a->>'kind' not in('owner','staff') then raise exception '관리자 또는 직원 로그인이 필요합니다.';end if; -- unified_guest_access_v1$new$);
 old:=$old$if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 온라인 관리 권한이 없습니다.';end if;$old$;
 if strpos(f,old)=0 then raise exception 'online property guard changed';end if;
 replacement:=$new$
 if not coalesce(omg_private.guest_can_access((a->>'property_id')::uuid,home),false) then raise exception '이 지점의 온라인 관리 권한이 없습니다.';end if;
 if (a->>'kind'='staff' or not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false)) and p_action not in('auth','guest_settings','inbox','thread','peek_thread','unread','read_message','prepare_send','reject','save_period','bookings','booking_data','booking_data_count') then raise exception '관리자 설정 권한이 필요합니다.';end if;
 if p_action='auth' then
  if (a->>'kind'='staff' or not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false)) and coalesce(p_data->>'request_action','') not in('guest_settings','inbox','thread','peek_thread','unread','read_message','send','draft','reject','translate','translate_reply','save_period','bookings','sync_bookings','booking_data','sync_booking_data','booking_data_count','sync_messages') then raise exception '관리자 설정 권한이 필요합니다.';end if;
  return jsonb_build_object('property_id',home,'actor',a->>'key','kind',a->>'kind');
 end if;
 if p_action='guest_settings' then
  return jsonb_build_object('ok',true,'property_id',home,'property_name',(select name from public.properties where id=home),'timezone',(select timezone from public.properties where id=home),
   'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name)),'[]') from public.properties p where omg_private.guest_can_access((a->>'property_id')::uuid,p.id)),
   'connected',exists(select 1 from omg_private.online_connections co where co.property_id=home and co.beds_property_id is not null),
   'beds_property_id',(select co.beds_property_id from omg_private.online_connections co where co.property_id=home),
   'synced_at',(select co.synced_at from omg_private.online_connections co where co.property_id=home),
   'incoming_translation_language',coalesce((select co.incoming_translation_language from omg_private.online_connections co where co.property_id=home),'ko'),
   'auto_translate',coalesce((select co.auto_translate from omg_private.online_connections co where co.property_id=home),false),
   'translation_excluded_languages',coalesce((select to_jsonb(co.translation_excluded_languages) from omg_private.online_connections co where co.property_id=home),'[]'::jsonb),
   'properties','[]'::jsonb,'ai_mode','off');
 end if;
$new$;
 f:=replace(f,old,replacement);execute f;
 end if;
end $patch$;
-- Filter the presentation feed, not the notification transport or recipient records.
do $patch$
declare f text;anchor text:=$a$(m.sender_type='system' or m.message_type in$a$;begin
 f:=pg_get_functiondef('public.list_notification_bot_messages(uuid,timestamptz,uuid)'::regprocedure);
 if strpos(f,'unified_guest_bot_filter_v1')=0 then
  if strpos(f,anchor)=0 then raise exception 'Bot visibility anchor changed';end if;
  f:=replace(f,anchor,$b$coalesce(m.source,'')<>'beds24' and coalesce(m.message_type,'')<>'guest_chat' and (m.sender_type='system' or m.message_type in$b$);
  f:=replace(f,'begin','begin -- unified_guest_bot_filter_v1'||chr(10));execute f;
 end if;
end $patch$;
commit;
