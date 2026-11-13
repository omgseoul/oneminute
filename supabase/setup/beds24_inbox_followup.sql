-- Private, property-scoped inbox metadata; no Beds24 API requests are needed.
create index if not exists online_message_direction on omg_private.online_messages(property_id,booking_id,source,sent_at desc,id desc);
create index if not exists online_outbox_sent_booking on omg_private.online_outbox(property_id,booking_id,updated_at desc) where status='sent';

create or replace function omg_private.online_inbox_followup(p_property uuid,p_action text,p_data jsonb,p_timezone text) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_from date:=nullif(p_data->>'message_from','')::date;v_to date:=nullif(p_data->>'message_to','')::date;tz text:=coalesce(nullif(p_timezone,''),'Asia/Seoul');local_day date;result jsonb;begin
 if (v_from is null)<>(v_to is null) or v_to<v_from then raise exception '조회 기간을 확인해주세요.';end if;
 if coalesce(p_data->>'direction','all') not in('all','guest','host') then raise exception '수신·발신 구분을 확인해주세요.';end if;
 if p_data ? 'stay_types' and (jsonb_typeof(p_data->'stay_types')<>'array' or exists(select 1 from jsonb_array_elements_text(p_data->'stay_types') x where x not in('checkin','staying','checkout','other'))) then raise exception '숙박 구분을 확인해주세요.';end if;
 local_day:=(now() at time zone tz)::date;
 if p_action='unread' then
  return jsonb_build_object('ok',true,'unread',(select count(*) from omg_private.online_messages m where m.property_id=p_property and m.source='guest' and m.read_at is null and (v_from is null or m.sent_at >= (v_from::timestamp at time zone tz) and m.sent_at < ((v_to+1)::timestamp at time zone tz))));
 end if;
 with latest as (
  select distinct on(m.booking_id) m.booking_id,m.sent_at,m.body preview,m.id message_id,m.source,
   coalesce(b.guest_name,'예약 #'||m.booking_id) guest_name,b.room_name,b.arrival,b.departure,b.status,b.channel
  from omg_private.online_messages m left join omg_private.online_bookings b on b.property_id=m.property_id and b.id=m.booking_id
  where m.property_id=p_property and (coalesce(p_data->>'direction','all')='all' or m.source=p_data->>'direction')
   and (v_from is null or m.sent_at >= (v_from::timestamp at time zone tz) and m.sent_at < ((v_to+1)::timestamp at time zone tz))
   and (not (p_data ? 'statuses') or coalesce(nullif(b.status,''),'unknown') in(select jsonb_array_elements_text(p_data->'statuses')))
   and (not (p_data ? 'stay_types')
    or p_data->'stay_types' ? 'checkin' and b.arrival=local_day
    or p_data->'stay_types' ? 'staying' and b.arrival<local_day and b.departure>local_day
    or p_data->'stay_types' ? 'checkout' and b.departure=local_day
    or p_data->'stay_types' ? 'other' and not(coalesce(b.arrival=local_day,false) or coalesce(b.arrival<local_day and b.departure>local_day,false) or coalesce(b.departure=local_day,false)))
  order by m.booking_id,m.sent_at desc,m.id desc
 ), enriched as (
  select l.*,u.unread,g.sent_at last_guest_at,
   coalesce(g.id is not null and (exists(select 1 from omg_private.online_messages h where h.property_id=p_property and h.booking_id=l.booking_id and h.source='host' and (h.sent_at,h.id)>(g.sent_at,g.id))
    or exists(select 1 from omg_private.online_outbox o where o.property_id=p_property and o.booking_id=l.booking_id and o.status='sent' and o.updated_at>g.sent_at)),false) replied,
   (select count(*) from omg_private.online_outbox o where o.property_id=p_property and o.booking_id=l.booking_id and o.status='draft') drafts,
   (select o.original_body from omg_private.online_outbox o where o.property_id=p_property and o.booking_id=l.booking_id and o.status='sent' and o.original_body is not null and l.source='host' and ((o.result->'remote'->>'id')=l.message_id::text or ((o.result->'remote'->>'id') is null and o.body=l.preview and abs(extract(epoch from o.updated_at-l.sent_at))<300)) order by o.updated_at desc limit 1) original_body
  from latest l
  left join lateral(select m.id,m.sent_at from omg_private.online_messages m where m.property_id=p_property and m.booking_id=l.booking_id and m.source='guest' order by m.sent_at desc,m.id desc limit 1)g on true
  cross join lateral(select count(*) unread from omg_private.online_messages m where m.property_id=p_property and m.booking_id=l.booking_id and m.source='guest' and m.read_at is null and (v_from is null or m.sent_at >= (v_from::timestamp at time zone tz) and m.sent_at < ((v_to+1)::timestamp at time zone tz)))u
 ), selected as (
  select e.*,e.last_guest_at is not null and not e.replied needs_reply from enriched e
  where (not coalesce((p_data->>'unread_only')::boolean,false) or e.unread>0)
   and (not coalesce((p_data->>'unreplied_only')::boolean,false) or e.last_guest_at is not null and not e.replied)
  order by e.sent_at desc,e.booking_id desc limit 300 offset greatest(0,least(15000,coalesce((p_data->>'offset')::int,0)))
 )select coalesce(jsonb_agg(to_jsonb(s) order by s.sent_at desc,s.booking_id desc),'[]') into result from selected s;
 return jsonb_build_object('ok',true,'threads',result,'synced_at',(select synced_at from omg_private.online_connections where property_id=p_property));
end$$;
revoke all on function omg_private.online_inbox_followup(uuid,text,jsonb,text) from public,anon,authenticated;
grant execute on function omg_private.online_inbox_followup(uuid,text,jsonb,text) to service_role;

create or replace function omg_private.online_read_through(p_property uuid,p_message bigint) returns jsonb language plpgsql security invoker set search_path='' as $$
declare anchor omg_private.online_messages%rowtype;begin
 select * into anchor from omg_private.online_messages where property_id=p_property and id=p_message and source='guest';
 if not found then return jsonb_build_object('ok',true);end if;
 update omg_private.online_messages m set read_at=now() where m.property_id=p_property and m.booking_id=anchor.booking_id and m.source='guest' and m.read_at is null and (m.sent_at,m.id)<=(anchor.sent_at,anchor.id);
 return jsonb_build_object('ok',true,'booking_id',anchor.booking_id,'read_through',anchor.sent_at,'read_through_id',anchor.id);
end$$;
revoke all on function omg_private.online_read_through(uuid,bigint) from public,anon,authenticated;
grant execute on function omg_private.online_read_through(uuid,bigint) to service_role;

-- Preserve the live translation and authorization paths, replacing only these actions.
do $patch$
declare definition text;start_at int;end_at int;begin
 definition:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 start_at:=strpos(definition,' elsif p_action in(''inbox'',''unread'') then');end_at:=strpos(definition,' elsif p_action=''save_period'' then');
 if start_at=0 or end_at<=start_at then raise exception '온라인 목록 함수의 변경 위치를 확인해주세요.';end if;
 definition:=substr(definition,1,start_at-1)||E' elsif p_action in(''inbox'',''unread'') then\n  return omg_private.online_inbox_followup(home,p_action,p_data,tz);\n'||substr(definition,end_at);
 start_at:=strpos(definition,' elsif p_action=''read_message'' then');end_at:=strpos(definition,' elsif p_action=''webhook_logs'' then');
 if start_at=0 or end_at<=start_at then raise exception '온라인 읽음 함수의 변경 위치를 확인해주세요.';end if;
 definition:=substr(definition,1,start_at-1)||E' elsif p_action=''read_message'' then\n  return omg_private.online_read_through(home,(p_data->>''message_id'')::bigint);\n'||substr(definition,end_at);
 execute definition;
end $patch$;
