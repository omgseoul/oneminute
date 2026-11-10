-- Small, retryable requests keep large video JSON out of the message transaction.
create table omg_private.staff_chat_upload_chunks (
 actor_key text not null,client_id uuid not null,peer text not null,mime_type text not null,
 part_index integer not null,total_parts integer not null,image_bytes bytea not null,
 expires_at timestamptz not null default clock_timestamp()+interval '1 day',
 primary key(actor_key,client_id,part_index),
 check(total_parts between 1 and 20 and part_index>=0 and part_index<total_parts),
 check(octet_length(image_bytes) between 1 and 1048576),
 check(mime_type in('video/mp4','video/webm'))
);
alter table omg_private.staff_chat_upload_chunks enable row level security;
revoke all on omg_private.staff_chat_upload_chunks from public,anon,authenticated;
create index staff_chat_upload_expiry on omg_private.staff_chat_upload_chunks(expires_at);

create function public.staff_chat_upload_chunk(p_access_token uuid,p_client_id uuid,p_peer text,p_mime_type text,p_part_index integer,p_total_parts integer,p_chunk text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text;bytes bytea;old omg_private.staff_chat_upload_chunks%rowtype;profile jsonb;
begin
 actor:=omg_private.guest_actor(p_access_token)->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_client_id is null or p_peer is null or p_mime_type is null or p_mime_type not in('video/mp4','video/webm') or p_total_parts is null or p_total_parts not between 1 and 20 or p_part_index is null or p_part_index<0 or p_part_index>=p_total_parts or p_chunk is null or octet_length(p_chunk)>1398104 then raise exception '첨부 파일 정보를 확인해주세요.';end if;
 profile:=public.staff_chat_peer_profile(p_access_token,p_peer);
 if not coalesce((profile->>'ok')::boolean,false) then raise exception '이 대화에 접근할 수 없습니다.';end if;
 bytes:=decode(p_chunk,'base64');
 if octet_length(bytes) not between 1 and 1048576 or (p_part_index<p_total_parts-1 and octet_length(bytes)<>1048576) then raise exception '첨부 파일 조각 크기가 올바르지 않습니다.';end if;
 if p_part_index=0 then perform omg_private.decode_staff_attachment('data:'||p_mime_type||';base64,'||p_chunk);end if;
 perform pg_advisory_xact_lock(hashtextextended(actor,410));
 delete from omg_private.staff_chat_upload_chunks where actor_key=actor and expires_at<clock_timestamp();
 if exists(select 1 from omg_private.staff_chat_upload_chunks where actor_key=actor and client_id=p_client_id and (peer<>p_peer or mime_type<>p_mime_type or total_parts<>p_total_parts)) then raise exception '전송 번호의 첨부 파일이 일치하지 않습니다.';end if;
 select * into old from omg_private.staff_chat_upload_chunks where actor_key=actor and client_id=p_client_id and part_index=p_part_index;
 if found then
  if old.image_bytes<>bytes then raise exception '전송 번호의 첨부 파일이 일치하지 않습니다.';end if;
  return jsonb_build_object('ok',true,'duplicate',true);
 end if;
 if not exists(select 1 from omg_private.staff_chat_upload_chunks where actor_key=actor and client_id=p_client_id)
 and (select count(distinct client_id) from omg_private.staff_chat_upload_chunks c where actor_key=actor and not exists(select 1 from omg_private.staff_chat_sends s where s.actor_key=c.actor_key and s.client_id=c.client_id))>=5 then raise exception '진행 중인 첨부 전송을 먼저 완료해주세요.';end if;
 insert into omg_private.staff_chat_upload_chunks(actor_key,client_id,peer,mime_type,part_index,total_parts,image_bytes)
 values(actor,p_client_id,p_peer,p_mime_type,p_part_index,p_total_parts,bytes);
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.staff_chat_upload_chunk(uuid,uuid,text,text,integer,integer,text) from public;
grant execute on function public.staff_chat_upload_chunk(uuid,uuid,text,text,integer,integer,text) to anon,authenticated;

create function omg_private.staff_chat_uploaded_attachment(p_actor text,p_client uuid,p_peer text,out image_bytes bytea,out mime_type text)
returns record language plpgsql set search_path='' as $$
declare parts integer;expected integer;
begin
 select count(*),max(total_parts),max(c.mime_type),string_agg(c.image_bytes,''::bytea order by part_index)
 into parts,expected,mime_type,image_bytes from omg_private.staff_chat_upload_chunks c
 where actor_key=p_actor and client_id=p_client and peer=p_peer and expires_at>clock_timestamp();
 if parts=0 or parts<>expected or octet_length(image_bytes)>20971520 then raise exception '동영상 업로드가 완료되지 않았습니다. 다시 시도해주세요.';end if;
end $$;
revoke all on function omg_private.staff_chat_uploaded_attachment(text,uuid,text) from public,anon,authenticated;
select cron.schedule('oms-chat-upload-cleanup','27 * * * *',$$delete from omg_private.staff_chat_upload_chunks where expires_at<clock_timestamp()$$);

CREATE OR REPLACE FUNCTION omg_private.staff_chat_core(p_access_token uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';result jsonb;items jsonb;person jsonb;allowed jsonb;
 client uuid;mid uuid;old omg_private.staff_chat_sends%rowtype;ids uuid[];lasttime timestamptz;lastid uuid;
 attachment_bytes bytea;attachment_mime text;
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
 
 if coalesce((p_data->>'uploaded')::boolean,false) then
  if p_data->>'photo' is not null then raise exception '첨부 전송 방식을 확인해주세요.';end if;
  select image_bytes,mime_type into attachment_bytes,attachment_mime from omg_private.staff_chat_uploaded_attachment(actor,(p_data->>'client_id')::uuid,p_data->>'peer');
 else
  select image_bytes,mime_type into attachment_bytes,attachment_mime from omg_private.decode_staff_attachment(p_data->>'photo');
 end if;
 client:=(p_data->>'client_id')::uuid;if client is null then raise exception '전송 번호가 필요합니다.';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor||client,0));
 select * into old from omg_private.staff_chat_sends where actor_key=actor and client_id=client;
 if found then
 if (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 attachment_bytes
 or (select mime_type from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 attachment_mime then raise exception '전송 번호의 첨부 파일이 일치하지 않습니다.';end if;
 if old.peer<>peerkey or old.body<>btrim(p_data->>'body') or old.priority<>coalesce(p_data->>'priority','normal') then raise exception '전송 번호가 중복되었습니다.';end if;
 return jsonb_build_object('ok',true,'message_id',old.message_id,'duplicate',true);
 end if;
 result:=public.send_shared_property_message(p_access_token,
 case when peerkey like 'employee:%' then array[(person->>'employee_id')::uuid] else '{}'::uuid[] end,
 case when peerkey like 'owner:%' then array[(person->>'owner_id')::uuid] else '{}'::uuid[] end,
 p_data->>'body',coalesce(p_data->>'priority','normal'),'general');
 if not (result->>'ok')::boolean then return result;end if;
 insert into omg_private.staff_chat_sends values(actor,client,peerkey,btrim(p_data->>'body'),coalesce(p_data->>'priority','normal'),(result->>'message_id')::uuid);

 if attachment_bytes is not null then
 insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type)
 values((result->>'message_id')::uuid,attachment_bytes,
   attachment_mime);
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
CREATE OR REPLACE FUNCTION omg_private.staff_group_rpc(p_access_token uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;gid uuid;client uuid;peers text[];existing text[];allowed jsonb;person jsonb;
 result jsonb;items jsonb;receipts jsonb;mid uuid;old omg_private.staff_chat_sends%rowtype;
 body text:=btrim(coalesce(p_data->>'body',''));priority text:=coalesce(p_data->>'priority','normal');
 ids uuid[];stamp timestamptz;anchor_time timestamptz;anchor_id uuid;property uuid;business uuid;changed integer;
 attachment_bytes bytea;attachment_mime text;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='create_group' then
  if jsonb_typeof(p_data->'peers') is distinct from 'array' or jsonb_array_length(p_data->'peers') not between 2 and 100 then
   raise exception '단체 대화 상대를 2명 이상 선택해주세요. (최대 100명)';end if;
  select array_agg(distinct value order by value) into peers from jsonb_array_elements_text(p_data->'peers');
  if cardinality(peers)<>jsonb_array_length(p_data->'peers') or actor=any(peers) then raise exception '대화 상대를 확인해주세요.';end if;
  allowed:=public.list_property_messages(p_access_token)->'recipients';
  if exists(select 1 from unnest(peers) k where not exists(select 1 from jsonb_array_elements(allowed) j where j->>'recipient_key'=k)) then
   raise exception '대화 권한이 없는 직원이 포함되어 있습니다.';end if;
  client:=(p_data->>'client_id')::uuid;if client is null then raise exception '생성 번호가 필요합니다.';end if;
  perform pg_advisory_xact_lock(hashtextextended(actor||client,72));
  select g.id into gid from omg_private.staff_groups g where g.created_by=actor and g.client_id=client;
  if gid is not null then
   select array_agg(m.actor_key order by m.actor_key) into existing from omg_private.staff_group_members m where m.group_id=gid and m.actor_key<>actor;
   if peers is distinct from existing then raise exception '생성 번호가 중복되었습니다.';end if;
   if not exists(select 1 from omg_private.staff_group_members m where m.group_id=gid and m.actor_key=actor and m.left_at is null) then raise exception '이미 나간 대화입니다.';end if;
  else
   insert into omg_private.staff_groups(property_id,created_by,client_id) values((a->>'property_id')::uuid,actor,client) returning id into gid;
   insert into omg_private.staff_group_members(group_id,actor_key) select gid,k from unnest(peers||array[actor]) k;
  end if;
  return jsonb_build_object('ok',true,'peer','group:'||gid);
 end if;
 if p_action='rooms' then
  select coalesce(jsonb_agg(jsonb_build_object('peer','group:'||g.id,'name',coalesce(names.title,'단체 대화'),
    'is_group',true,'member_count',names.n,'property_id',a->>'property_id','property_name','',
    'preview',coalesce(latest.body,'대화를 시작하세요.'),'priority',coalesce(latest.priority,'normal'),
    'updated_at',coalesce(latest.created_at,g.created_at),'unread',(select count(*) from omg_private.staff_group_items(actor,g.id) i where not i.mine and not i.system and i.read_at is null))
    order by coalesce(latest.created_at,g.created_at) desc,g.id),'[]') into items
  from omg_private.staff_groups g join omg_private.staff_group_members member on member.group_id=g.id and member.actor_key=actor and member.left_at is null
  left join lateral(select string_agg(display_name,', ' order by display_name) title,count(*) n from omg_private.staff_group_people(g.id))names on true
  left join lateral(select * from omg_private.staff_group_items(actor,g.id) order by created_at desc,id desc limit 1)latest on true;
  return jsonb_build_object('ok',true,'rooms',items);
 end if;
 if coalesce(p_data->>'peer','') !~ '^group:[0-9a-f-]{36}$' then raise exception '단체 대화방을 확인해주세요.';end if;
 gid:=substring(p_data->>'peer' from 7)::uuid;
 -- Serialize sends and departures so a departed member cannot receive later messages.
 perform 1 from omg_private.staff_groups where id=gid for update;
 if not exists(select 1 from omg_private.staff_group_members m where m.group_id=gid and m.actor_key=actor and m.left_at is null) then
  raise exception '참여 중인 단체 대화방이 아닙니다.';end if;
 if p_action='profile' then
  select jsonb_build_object('kind','group','display_name',coalesce(string_agg(display_name,', ' order by display_name),'단체 대화'),
   'member_count',count(*),'members',coalesce(jsonb_agg(to_jsonb(p) order by display_name),'[]')) into person from omg_private.staff_group_people(gid)p;
  return jsonb_build_object('ok',true,'profile',person);
 end if;
 if p_action='leave' then
  stamp:=clock_timestamp();
  update omg_private.staff_group_members set left_at=stamp where group_id=gid and actor_key=actor;
  update public.property_message_recipients r set read_at=coalesce(read_at,stamp)
   where r.recipient_key=actor and exists(select 1 from omg_private.staff_group_messages gm where gm.group_id=gid and gm.message_id=r.message_id);
  select p.id,p.business_id into property,business from public.properties p where p.id=(a->>'property_id')::uuid;
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,source,require_signature,require_understanding)
   values(business,property,a->>'kind',case when a->>'kind'='owner' then (a->>'id')::uuid end,
    case when a->>'kind'='staff' then (a->>'id')::uuid end,(a->>'name')||'님이 채팅방을 나갔습니다.','staff_group_chat',false,false) returning id into mid;
  insert into omg_private.staff_group_messages values(mid,gid,true);
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id,read_at)
   select mid,p.actor_key,case when p.actor_key like 'owner:%' then 'owner' else 'staff' end,
    case when p.actor_key like 'owner:%' then split_part(p.actor_key,':',2)::uuid end,
    case when p.actor_key like 'employee:%' then split_part(p.actor_key,':',2)::uuid end,stamp from omg_private.staff_group_people(gid)p;
  return jsonb_build_object('ok',true);
 end if;
 if p_action='send' then
  if length(body) not between 1 and 2000 or priority not in('normal','urgent') then raise exception '메시지 내용을 확인해주세요.';end if;
  if (select count(*) from omg_private.staff_group_people(gid))<2 then raise exception '남아 있는 대화 상대가 없습니다.';end if;
  -- Attachment validation is shared with the existing direct-chat format.
 if coalesce((p_data->>'uploaded')::boolean,false) then
  if p_data->>'photo' is not null then raise exception '첨부 전송 방식을 확인해주세요.';end if;
  select image_bytes,mime_type into attachment_bytes,attachment_mime from omg_private.staff_chat_uploaded_attachment(actor,(p_data->>'client_id')::uuid,p_data->>'peer');
 else
  select image_bytes,mime_type into attachment_bytes,attachment_mime from omg_private.decode_staff_attachment(p_data->>'photo');
 end if;
  client:=(p_data->>'client_id')::uuid;if client is null then raise exception '전송 번호가 필요합니다.';end if;
  perform pg_advisory_xact_lock(hashtextextended(actor||client,0));
  select * into old from omg_private.staff_chat_sends where actor_key=actor and client_id=client;
  if found then
   if old.peer<>p_data->>'peer' or old.body<>body or old.priority<>priority
    or (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from attachment_bytes
    or (select mime_type from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from attachment_mime
    then raise exception '전송 번호가 중복되었습니다.';end if;
   mid:=old.message_id;
  else
   select p.id,p.business_id into property,business from public.properties p where p.id=(a->>'property_id')::uuid;
   insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,source,require_signature,require_understanding)
    values(business,property,a->>'kind',case when a->>'kind'='owner' then (a->>'id')::uuid end,
     case when a->>'kind'='staff' then (a->>'id')::uuid end,body,priority,'staff_group_chat',false,false) returning id into mid;
   insert into omg_private.staff_group_messages values(mid,gid,false);
   insert into omg_private.staff_chat_sends values(actor,client,p_data->>'peer',body,priority,mid);
   if attachment_bytes is not null then insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type)
    values(mid,attachment_bytes,attachment_mime);end if;
   insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)
    select mid,p.actor_key,case when p.actor_key like 'owner:%' then 'owner' else 'staff' end,
     case when p.actor_key like 'owner:%' then split_part(p.actor_key,':',2)::uuid end,
     case when p.actor_key like 'employee:%' then split_part(p.actor_key,':',2)::uuid end
    from omg_private.staff_group_people(gid)p where p.actor_key<>actor;
  end if;
  return jsonb_build_object('ok',true,'message_id',mid,'message',(select to_jsonb(i)||jsonb_build_object('attachment_type',f.mime_type)
   from omg_private.staff_group_items(actor,gid)i left join omg_private.staff_chat_photos f on f.message_id=i.id where i.id=mid));
 end if;
 if p_action='attachment' then
  select jsonb_build_object('ok',true,'mime_type',f.mime_type,'attachment','data:'||f.mime_type||';base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'')) into result
   from omg_private.staff_chat_photos f join omg_private.staff_group_messages gm on gm.message_id=f.message_id
   where gm.group_id=gid and f.message_id=(p_data->>'message_id')::uuid;
  if result is null then raise exception '대화 첨부 파일에 접근할 수 없습니다.';end if;return result;
 end if;
 if p_action in('read','read_room') then
  if p_action='read_room' then
   select i.created_at,i.id into anchor_time,anchor_id from omg_private.staff_group_items(actor,gid)i where i.id=(p_data->>'through_id')::uuid;
   if anchor_id is null then raise exception '확인한 대화 위치를 찾을 수 없습니다.';end if;
   select array_agg(i.id) into ids from omg_private.staff_group_items(actor,gid)i where (i.created_at,i.id)<=(anchor_time,anchor_id);
  else
   if jsonb_typeof(p_data->'ids') is distinct from 'array' or jsonb_array_length(p_data->'ids')>200 then raise exception '읽음 목록을 확인해주세요.';end if;
   select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_data->'ids');
  end if;
  update public.property_message_recipients r set read_at=clock_timestamp() where r.recipient_key=actor and r.read_at is null and r.message_id=any(ids)
   and exists(select 1 from omg_private.staff_group_messages gm where gm.group_id=gid and gm.message_id=r.message_id);
  get diagnostics changed=row_count;
  return jsonb_build_object('ok',true,'read_count',changed,'read_through_id',anchor_id,'read_ids',coalesce(to_jsonb(ids),'[]'));
 end if;
 if p_action<>'messages' then raise exception '잘못된 요청입니다.';end if;
 if jsonb_typeof(coalesce(p_data->'receipt_ids','[]'))<>'array' or jsonb_array_length(coalesce(p_data->'receipt_ids','[]'))>200 then raise exception '읽음 목록을 확인해주세요.';end if;
 select array_agg(value::uuid) into ids from jsonb_array_elements_text(coalesce(p_data->'receipt_ids','[]'));
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'read_at',i.read_at,'unread_count',i.unread_count)),'[]') into receipts from omg_private.staff_group_items(actor,gid)i where i.mine and i.id=any(ids);
 with page as(select * from omg_private.staff_group_items(actor,gid)i
  where (p_data->>'before_time' is null or (i.created_at,i.id)<((p_data->>'before_time')::timestamptz,(p_data->>'before_id')::uuid))
   and(p_data->>'after_time' is null or (i.created_at,i.id)>((p_data->>'after_time')::timestamptz,(p_data->>'after_id')::uuid))
  order by case when p_data->>'after_time' is not null then i.created_at end asc,
   case when p_data->>'after_time' is not null then i.id end asc,i.created_at desc,i.id desc limit 50)
 select coalesce(jsonb_agg(to_jsonb(page)||jsonb_build_object('attachment_type',f.mime_type,
  'photo',case when f.mime_type='image/jpeg' then 'data:image/jpeg;base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'') end) order by page.created_at,page.id),'[]') into items
 from page left join omg_private.staff_chat_photos f on f.message_id=page.id;
 person:=omg_private.staff_group_rpc(p_access_token,'profile',p_data)->'profile';
 return jsonb_build_object('ok',true,'peer',person,'can_send',(select count(*)>1 from omg_private.staff_group_people(gid)),'messages',items,'receipts',receipts);
end $function$

;
