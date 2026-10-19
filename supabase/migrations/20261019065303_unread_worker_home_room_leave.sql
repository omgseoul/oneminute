begin;
-- Per-account room visibility; nobody else's messages or membership is deleted.
create table omg_private.staff_chat_departures(
 actor_key text not null,peer text not null,left_at timestamptz not null,
 primary key(actor_key,peer),check(actor_key<>peer)
);
create table omg_private.staff_chat_events(
 id uuid primary key default gen_random_uuid(),actor_key text not null,peer text not null,
 actor_name text not null,created_at timestamptz not null default clock_timestamp()
);
create index staff_chat_events_peer_time on omg_private.staff_chat_events(peer,created_at,id);
alter table omg_private.staff_chat_departures enable row level security;
alter table omg_private.staff_chat_events enable row level security;
revoke all on omg_private.staff_chat_departures,omg_private.staff_chat_events from public,anon,authenticated;
CREATE OR REPLACE FUNCTION omg_private.staff_conversation_items(p_actor text)
 RETURNS TABLE(id uuid, peer text, body text, priority text, created_at timestamp with time zone, mine boolean, read_at timestamp with time zone, broadcast boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select m.id,case when s.key=p_actor then r.recipient_key else s.key end,m.message,m.priority,m.created_at,
 s.key=p_actor,r.read_at,(select count(*)>1 from public.property_message_recipients rr where rr.message_id=m.id)
 from public.property_messages m
 cross join lateral(select case when m.sender_type='owner' then 'owner:'||m.sender_owner_id when m.sender_type='staff' then 'employee:'||m.sender_employee_id end key)s
 join public.property_message_recipients r on r.message_id=m.id
 where m.message_type in('general','emergency_report') and s.key is not null
 and m.message !~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]'
 and (s.key=p_actor or r.recipient_key=p_actor) and s.key<>r.recipient_key
 and not exists(select 1 from omg_private.staff_chat_departures d where d.actor_key=p_actor
   and d.peer=case when s.key=p_actor then r.recipient_key else s.key end and m.created_at<=d.left_at)
 union all
 select ev.id,ev.actor_key,ev.actor_name||'님이 채팅방을 나갔습니다.','normal',ev.created_at,false,ev.created_at,false
 from omg_private.staff_chat_events ev where ev.peer=p_actor
 and not exists(select 1 from omg_private.staff_chat_departures d where d.actor_key=p_actor and d.peer=ev.actor_key and ev.created_at<=d.left_at);
$function$

;
CREATE OR REPLACE FUNCTION omg_private.staff_chat_core(p_access_token uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';result jsonb;items jsonb;person jsonb;allowed jsonb;
 client uuid;mid uuid;old omg_private.staff_chat_sends%rowtype;ids uuid[];lasttime timestamptz;lastid uuid;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='rooms' then
 with items as(select * from omg_private.staff_conversation_items(actor)),
 latest as(select distinct on(peer) * from items order by peer,created_at desc,id desc)
 select coalesce(jsonb_agg(jsonb_build_object('peer',l.peer,'name',coalesce(o.display_name,e.display_name,'이전 계정'),
 'profile_image',coalesce(o.profile_image,e.profile_image),'property_name',p.name,'property_id',p.id,'preview',l.body,'priority',l.priority,
 'updated_at',l.created_at,'unread',(select count(*) from items i where i.peer=l.peer and not i.mine and i.read_at is null))
 order by l.created_at desc,l.id desc),'[]') into result from latest l
 left join public.owners o on 'owner:'||o.id=l.peer left join public.employees e on 'employee:'||e.id=l.peer
 left join public.properties p on p.id=coalesce(o.property_id,e.property_id);
 return jsonb_build_object('ok',true,'rooms',result);
 end if;
 if p_action='resolve' then
 select i.peer into peerkey from omg_private.staff_conversation_items(actor)i where i.id=(p_data->>'message_id')::uuid order by i.peer limit 1;
 if peerkey is null then raise exception '대화를 찾을 수 없습니다.';end if;
 return jsonb_build_object('ok',true,'peer',peerkey);
 end if;
 if p_action not in('messages','read','send','attachment') then raise exception '잘못된 요청입니다.';end if;
 -- New conversations use the same recipient permissions as the original messenger.
 allowed:=public.list_property_messages(p_access_token)->'recipients';
 select j into person from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey;
 if person is null and not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
 raise exception '이 대화에 접근할 수 없습니다.';end if;
 if p_action='send' then
 if person is null then raise exception '현재 이 계정에 메세지를 보낼 수 없습니다.';end if;
 
 if p_data->>'photo' is not null then
  if (p_data->>'photo' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$'
      and p_data->>'photo' !~ '^data:video/webm;base64,[A-Za-z0-9+/]+={0,2}$'
      and p_data->>'photo' !~ '^data:video/mp4;base64,[A-Za-z0-9+/]+={0,2}$')
     or octet_length(decode(split_part(p_data->>'photo',',',2),'base64')) not between 3 and 20971520 then
   raise exception '사진은 1.5MB, 동영상은 압축 후 20MB 이하만 보낼 수 있습니다.';
  end if;
  if p_data->>'photo' like 'data:image/%' and
     (octet_length(decode(split_part(p_data->>'photo',',',2),'base64'))>1572864
      or substring(decode(split_part(p_data->>'photo',',',2),'base64') from 1 for 3)<>decode('ffd8ff','hex')) then
   raise exception '올바른 JPEG 사진이 아닙니다.';
  end if;
  if p_data->>'photo' like 'data:video/webm%' and
     substring(decode(split_part(p_data->>'photo',',',2),'base64') from 1 for 4)<>decode('1a45dfa3','hex') then
   raise exception '올바른 WebM 동영상이 아닙니다.';
  end if;
  if p_data->>'photo' like 'data:video/mp4%' and
     (octet_length(decode(split_part(p_data->>'photo',',',2),'base64'))<12
      or substring(decode(split_part(p_data->>'photo',',',2),'base64') from 5 for 4)<>decode('66747970','hex')) then
   raise exception '올바른 MP4 동영상이 아닙니다.';
  end if;
 end if;
 client:=(p_data->>'client_id')::uuid;if client is null then raise exception '전송 번호가 필요합니다.';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor||client,0));
 select * into old from omg_private.staff_chat_sends where actor_key=actor and client_id=client;
 if found then
 if (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 decode(split_part(p_data->>'photo',',',2),'base64')
 or (select mime_type from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 split_part(split_part(p_data->>'photo',':',2),';',1) then raise exception '전송 번호의 첨부 파일이 일치하지 않습니다.';end if;
 if old.peer<>peerkey or old.body<>btrim(p_data->>'body') or old.priority<>coalesce(p_data->>'priority','normal') then raise exception '전송 번호가 중복되었습니다.';end if;
 return jsonb_build_object('ok',true,'message_id',old.message_id,'duplicate',true);
 end if;
 result:=public.send_shared_property_message(p_access_token,
 case when peerkey like 'employee:%' then array[(person->>'employee_id')::uuid] else '{}'::uuid[] end,
 case when peerkey like 'owner:%' then array[(person->>'owner_id')::uuid] else '{}'::uuid[] end,
 p_data->>'body',coalesce(p_data->>'priority','normal'),'general');
 if not (result->>'ok')::boolean then return result;end if;
 insert into omg_private.staff_chat_sends values(actor,client,peerkey,btrim(p_data->>'body'),coalesce(p_data->>'priority','normal'),(result->>'message_id')::uuid);

 if p_data->>'photo' is not null then
 insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type)
 values((result->>'message_id')::uuid,decode(split_part(p_data->>'photo',',',2),'base64'),
   split_part(split_part(p_data->>'photo',':',2),';',1));
 end if;
 return result;
 elsif p_action='attachment' then
  if nullif(p_data->>'message_id','') is null then raise exception '첨부 파일을 찾을 수 없습니다.';end if;
  select jsonb_build_object('ok',true,'mime_type',f.mime_type,
    'attachment','data:'||f.mime_type||';base64,'||replace(encode(f.image_bytes,'base64'),chr(10),''))
    into result
  from omg_private.staff_chat_photos f
  where f.message_id=(p_data->>'message_id')::uuid
    and exists(select 1 from omg_private.staff_conversation_items(actor)i
      where i.peer=peerkey and i.id=f.message_id);
  if result is null then raise exception '대화 첨부 파일에 접근할 수 없습니다.';end if;
  return result;
 elsif p_action='read' then
 -- Only acknowledge IDs actually displayed, never unseen pages or notices.
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'));
 update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
 where r.recipient_key=actor and r.message_id=any(ids) and exists(
 select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine and i.id=r.message_id);
 return jsonb_build_object('ok',true);
 end if;
 if jsonb_typeof(coalesce(p_data->'receipt_ids','[]'::jsonb))<>'array' then
  raise exception '읽음 확인 목록이 올바르지 않습니다.';
 end if;
 if jsonb_array_length(coalesce(p_data->'receipt_ids','[]'::jsonb))>200 then
  raise exception '한 번에 200개까지 읽음 상태를 확인할 수 있습니다.';
 end if;
 select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids
 from jsonb_array_elements_text(coalesce(p_data->'receipt_ids','[]'::jsonb));
 with page as(select * from omg_private.staff_conversation_items(actor)i where i.peer=peerkey
 and (p_data->>'before_time' is null or (i.created_at,i.id)<((p_data->>'before_time')::timestamptz,(p_data->>'before_id')::uuid))
 and (p_data->>'after_time' is null or (i.created_at,i.id)>((p_data->>'after_time')::timestamptz,(p_data->>'after_id')::uuid))
 order by case when p_data->>'after_time' is not null then i.created_at end asc,
 case when p_data->>'after_time' is not null then i.id end asc,i.created_at desc,i.id desc limit 50)
 select coalesce(jsonb_agg(to_jsonb(page)||jsonb_build_object(
   'photo',(select case when f.mime_type='image/jpeg' then 'data:image/jpeg;base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'') end from omg_private.staff_chat_photos f where f.message_id=page.id),
   'attachment_type',(select f.mime_type from omg_private.staff_chat_photos f where f.message_id=page.id)) order by created_at,id),'[]') into items from page;
 if person is null then
 select jsonb_build_object('display_name',coalesce(o.display_name,e.display_name,'이전 계정'),'profile_image',coalesce(o.profile_image,e.profile_image)) into person
 from (select peerkey k)x left join public.owners o on 'owner:'||o.id=x.k left join public.employees e on 'employee:'||e.id=x.k;
 end if;
 return jsonb_build_object('ok',true,'actor',a,'peer',person,'can_send',exists(select 1 from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey),'messages',items,'receipts',coalesce((
  select jsonb_agg(jsonb_build_object('id',i.id,'read_at',i.read_at) order by i.created_at,i.id)
  from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and i.mine and i.id=any(ids)
 ),'[]'::jsonb));
end$function$

;
revoke all on function omg_private.staff_chat_core(uuid,text,jsonb) from public,anon,authenticated;
create or replace function public.staff_chat_rpc(p_access_token uuid,p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';answer jsonb;stamp timestamptz;confirmed jsonb;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='leave' then
  if peerkey is null or peerkey!~'^(owner|employee):[0-9a-f-]{36}$' or peerkey=actor then raise exception '대화를 찾을 수 없습니다.';end if;
  perform pg_advisory_xact_lock(hashtextextended(actor||':'||peerkey,71));
  if not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
   return jsonb_build_object('ok',true,'already_left',true);
  end if;
  stamp:=clock_timestamp();
  update public.property_message_recipients r set read_at=coalesce(r.read_at,stamp)
  where r.recipient_key=actor and exists(select 1 from omg_private.staff_conversation_items(actor)i
    where i.peer=peerkey and not i.mine and i.id=r.message_id and i.created_at<=stamp);
  insert into omg_private.staff_chat_departures values(actor,peerkey,stamp)
  on conflict(actor_key,peer) do update set left_at=excluded.left_at;
  insert into omg_private.staff_chat_events(actor_key,peer,actor_name,created_at) values(actor,peerkey,coalesce(a->>'name','근무자'),stamp);
  return jsonb_build_object('ok',true);
 end if;
 answer:=omg_private.staff_chat_core(p_access_token,p_action,p_data);
 if p_action='read' then
  select coalesce(jsonb_agg(i.id),'[]'::jsonb) into confirmed from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and not i.mine and i.read_at is not null and i.id in(
    select value::uuid from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb)));
  return answer||jsonb_build_object('read_ids',confirmed,'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 elsif p_action='messages' then
  return jsonb_set(answer,'{messages}',coalesce((select jsonb_agg(item||jsonb_build_object('system',exists(
    select 1 from omg_private.staff_chat_events ev where ev.id=(item->>'id')::uuid)) order by ordinal)
    from jsonb_array_elements(answer->'messages') with ordinality as rows(item,ordinal)),'[]'::jsonb));
 end if;
 return answer;
end $function$;
revoke all on function public.staff_chat_rpc(uuid,text,jsonb) from public;
grant execute on function public.staff_chat_rpc(uuid,text,jsonb) to anon,authenticated,service_role;
commit;
