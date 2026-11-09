-- Group membership is the authorization boundary; all access uses validated OMS sessions.
create table omg_private.staff_groups (
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id),
 created_by text not null, client_id uuid not null, created_at timestamptz not null default clock_timestamp(),
 unique(created_by,client_id)
);
create table omg_private.staff_group_members (
 group_id uuid not null references omg_private.staff_groups(id) on delete cascade,
 actor_key text not null check(actor_key ~ '^(owner|employee):[0-9a-f-]{36}$'),
 joined_at timestamptz not null default clock_timestamp(), left_at timestamptz,
 primary key(group_id,actor_key)
);
create index staff_group_members_actor on omg_private.staff_group_members(actor_key,group_id) where left_at is null;
create table omg_private.staff_group_messages (
 message_id uuid primary key references public.property_messages(id) on delete cascade,
 group_id uuid not null references omg_private.staff_groups(id) on delete cascade,
 is_system boolean not null default false
);
create index staff_group_messages_group on omg_private.staff_group_messages(group_id,message_id);
alter table omg_private.staff_groups enable row level security;
alter table omg_private.staff_group_members enable row level security;
alter table omg_private.staff_group_messages enable row level security;
revoke all on omg_private.staff_groups,omg_private.staff_group_members,omg_private.staff_group_messages from public,anon,authenticated;

create function omg_private.staff_group_people(p_group uuid)
returns table(actor_key text,display_name text,profile_image text,property_id uuid,property_name text)
language sql stable set search_path='' as $$
 select gm.actor_key,coalesce(o.display_name,e.display_name),coalesce(o.profile_image,e.profile_image),p.id,p.name
 from omg_private.staff_group_members gm
 left join public.owners o on gm.actor_key='owner:'||o.id and o.active
 left join public.employees e on gm.actor_key='employee:'||e.id and e.active and e.role<>'owner'
 join public.properties p on p.id=coalesce(o.property_id,e.property_id)
 where gm.group_id=p_group and gm.left_at is null
$$;
create function omg_private.staff_group_items(p_actor text,p_group uuid)
returns table(id uuid,body text,priority text,created_at timestamptz,mine boolean,read_at timestamptz,
 unread_count bigint,sender_key text,sender_name text,sender_profile_image text,system boolean,broadcast boolean,client_id uuid)
language sql stable set search_path='' as $$
 select m.id,m.message,m.priority,m.created_at,s.key=p_actor,
 case when gm.is_system then m.created_at when s.key<>p_actor then r.read_at
      when coalesce(receipts.unread,0)=0 then coalesce(receipts.last_read,m.created_at) end,
 case when gm.is_system then 0 else coalesce(receipts.unread,0) end,
 s.key,coalesce(o.display_name,e.display_name,'이전 계정'),coalesce(o.profile_image,e.profile_image),gm.is_system,false,cs.client_id
 from omg_private.staff_group_messages gm join public.property_messages m on m.id=gm.message_id
 cross join lateral(select case when m.sender_type='owner' then 'owner:'||m.sender_owner_id else 'employee:'||m.sender_employee_id end key)s
 left join public.owners o on o.id=m.sender_owner_id
 left join public.employees e on e.id=m.sender_employee_id
 left join public.property_message_recipients r on r.message_id=m.id and r.recipient_key=p_actor
 left join omg_private.staff_chat_sends cs on cs.message_id=m.id and cs.actor_key=p_actor
 left join lateral(select count(*) filter(where rr.read_at is null) unread,max(rr.read_at) last_read
   from public.property_message_recipients rr join omg_private.staff_group_members member
    on member.group_id=p_group and member.actor_key=rr.recipient_key and member.left_at is null
   where rr.message_id=m.id)receipts on true
 where gm.group_id=p_group
$$;

create function omg_private.staff_group_rpc(p_access_token uuid,p_action text,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;actor text;gid uuid;client uuid;peers text[];existing text[];allowed jsonb;person jsonb;
 result jsonb;items jsonb;receipts jsonb;mid uuid;old omg_private.staff_chat_sends%rowtype;
 body text:=btrim(coalesce(p_data->>'body',''));priority text:=coalesce(p_data->>'priority','normal');
 ids uuid[];stamp timestamptz;anchor_time timestamptz;anchor_id uuid;property uuid;business uuid;changed integer;
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
   if old.peer<>p_data->>'peer' or old.body<>body or old.priority<>priority
    or (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from decode(split_part(p_data->>'photo',',',2),'base64')
    or (select mime_type from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from split_part(split_part(p_data->>'photo',':',2),';',1)
    then raise exception '전송 번호가 중복되었습니다.';end if;
   mid:=old.message_id;
  else
   select p.id,p.business_id into property,business from public.properties p where p.id=(a->>'property_id')::uuid;
   insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,source,require_signature,require_understanding)
    values(business,property,a->>'kind',case when a->>'kind'='owner' then (a->>'id')::uuid end,
     case when a->>'kind'='staff' then (a->>'id')::uuid end,body,priority,'staff_group_chat',false,false) returning id into mid;
   insert into omg_private.staff_group_messages values(mid,gid,false);
   insert into omg_private.staff_chat_sends values(actor,client,p_data->>'peer',body,priority,mid);
   if p_data->>'photo' is not null then insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type)
    values(mid,decode(split_part(p_data->>'photo',',',2),'base64'),split_part(split_part(p_data->>'photo',':',2),';',1));end if;
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
end $$;
revoke all on function omg_private.staff_group_people(uuid),omg_private.staff_group_items(text,uuid),omg_private.staff_group_rpc(uuid,text,jsonb) from public,anon,authenticated;

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
 where not exists(select 1 from omg_private.staff_group_messages gm where gm.message_id=m.id) and m.message_type in('general','emergency_report') and s.key is not null
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

CREATE OR REPLACE FUNCTION public.staff_chat_rpc(p_access_token uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';answer jsonb;stamp timestamptz;confirmed jsonb;seen_at timestamptz;seen_id uuid;changed_count integer;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;

 if p_action='create_group' or peerkey like 'group:%' then return omg_private.staff_group_rpc(p_access_token,p_action,p_data);end if;
 if p_action='rooms' then
  answer:=omg_private.staff_chat_core(p_access_token,p_action,p_data);
  return jsonb_build_object('ok',true,'rooms',coalesce((select jsonb_agg(j order by j->>'updated_at' desc) from jsonb_array_elements((answer->'rooms')||(omg_private.staff_group_rpc(p_access_token,'rooms','{}')->'rooms'))j),'[]'));
 end if;
 if p_action='resolve' then
  select 'group:'||gm.group_id into peerkey from omg_private.staff_group_messages gm where gm.message_id=(p_data->>'message_id')::uuid;
  if peerkey is not null then
   perform omg_private.staff_group_rpc(p_access_token,'profile',jsonb_build_object('peer',peerkey));
   return jsonb_build_object('ok',true,'peer',peerkey);
  end if;
  peerkey:=p_data->>'peer';
 end if;
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
 if p_action='read_room' then
  -- The opened room snapshot may end with our own replies/stickers. Its cursor
  -- acknowledges prior incoming history too, without touching later arrivals.
  select i.created_at,i.id into seen_at,seen_id from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and i.id=(p_data->>'through_id')::uuid;
  if seen_id is null then raise exception '확인한 대화 위치를 찾을 수 없습니다.';end if;
  update public.property_message_recipients r set read_at=clock_timestamp()
  where r.recipient_key=actor and r.read_at is null and exists(
   select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine
    and i.id=r.message_id and (i.created_at,i.id)<=(seen_at,seen_id));
  get diagnostics changed_count=row_count;
  return jsonb_build_object('ok',true,'read_count',changed_count,'read_through_id',seen_id,'read_through_at',seen_at,
   'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 end if;
 answer:=omg_private.staff_chat_core(p_access_token,p_action,p_data);
 if p_action='read' then
  select coalesce(jsonb_agg(i.id),'[]'::jsonb) into confirmed from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and not i.mine and i.read_at is not null and i.id in(
    select value::uuid from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb)));
  return answer||jsonb_build_object('read_ids',confirmed,'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 elsif p_action='send' and (answer->>'ok')::boolean then
  return answer||jsonb_build_object('message',(select to_jsonb(i)||jsonb_build_object('client_id',p_data->>'client_id','attachment_type',f.mime_type,'system',false) from omg_private.staff_conversation_items(actor)i left join omg_private.staff_chat_photos f on f.message_id=i.id where i.id=(answer->>'message_id')::uuid and i.peer=peerkey limit 1));
 elsif p_action='messages' then
  return jsonb_set(answer,'{messages}',coalesce((select jsonb_agg(item||jsonb_build_object('client_id',(select s.client_id from omg_private.staff_chat_sends s where s.message_id=(item->>'id')::uuid and s.actor_key=actor),'system',exists(
    select 1 from omg_private.staff_chat_events ev where ev.id=(item->>'id')::uuid)) order by ordinal)
    from jsonb_array_elements(answer->'messages') with ordinality as rows(item,ordinal)),'[]'::jsonb));
 end if;
 return answer;
end $function$

;

CREATE OR REPLACE FUNCTION public.staff_chat_peer_profile(p_access_token uuid, p_peer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor jsonb;
  actor_key text;
  is_allowed boolean:=false;
  profile jsonb;
begin
  actor:=omg_private.guest_actor(p_access_token);
  actor_key:=actor->>'key';
  if actor_key is null then
    return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  if p_peer like 'group:%' then return omg_private.staff_group_rpc(p_access_token,'profile',jsonb_build_object('peer',p_peer));end if;
  if p_peer is null or p_peer!~'^(owner|employee):[0-9a-f-]{36}$' then
    return jsonb_build_object('ok',false,'code','invalid_peer','message','대화 상대를 확인해주세요.');
  end if;

  select exists(
    select 1 from jsonb_array_elements(coalesce(public.list_property_messages(p_access_token)->'recipients','[]'::jsonb)) recipient
    where recipient->>'recipient_key'=p_peer
  ) or exists(
    select 1 from omg_private.staff_conversation_items(actor_key) item where item.peer=p_peer
  ) into is_allowed;

  if not is_allowed then
    return jsonb_build_object('ok',false,'code','forbidden','message','이 대화 상대의 정보를 볼 수 없습니다.');
  end if;

  if p_peer like 'employee:%' then
    select jsonb_build_object(
      'kind','employee','display_name',e.display_name,'profile_image',e.profile_image,
      'job_title',coalesce(e.job_title,''),'property_name',p.name,'contact_phone',coalesce(e.contact_phone,'')
    ) into profile
    from public.employees e join public.properties p on p.id=e.property_id
    where e.id=substring(p_peer from 10)::uuid;
  else
    select jsonb_build_object(
      'kind','owner','display_name',o.display_name,'profile_image',o.profile_image,
      'job_title','관리자','property_name',p.name,'contact_phone',''
    ) into profile
    from public.owners o join public.properties p on p.id=o.property_id
    where o.id=substring(p_peer from 7)::uuid;
  end if;

  if profile is null then
    return jsonb_build_object('ok',false,'code','not_found','message','근무자 정보를 찾을 수 없습니다.');
  end if;
  return jsonb_build_object('ok',true,'profile',profile);
end;
$function$

;
