begin;
-- Private attachments inherit the conversation's RPC authorization and message retention.
create table if not exists omg_private.staff_chat_photos (
 message_id uuid primary key references public.property_messages(id) on delete cascade,
 image_bytes bytea not null check(octet_length(image_bytes) between 3 and 1048576),
 created_at timestamptz not null default now()
);
alter table omg_private.staff_chat_photos enable row level security;
do $migration$
declare src text;
begin
 src:=pg_get_functiondef('public.staff_chat_rpc(uuid,text,jsonb)'::regprocedure);
 if position('staff_chat_photos' in src)=0 then
  if position('client:=(p_data' in src)=0 or position('to_jsonb(page) order by created_at,id' in src)=0 then raise exception 'Unexpected staff RPC definition';end if;
  src:=replace(src,'client:=(p_data', $patch$
 if p_data->>'photo' is not null then
  if length(p_data->>'photo')>1398127 or p_data->>'photo' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$' then raise exception '1MB 이하 JPEG 사진만 보낼 수 있습니다.';end if;
  if substring(decode(split_part(p_data->>'photo',',',2),'base64') from 1 for 3)<>decode('ffd8ff','hex') then raise exception '올바른 JPEG 사진이 아닙니다.';end if;
 end if;
 client:=(p_data$patch$);
  src:=replace(src,'if found then',$patch$if found then
 if (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 decode(split_part(p_data->>'photo',',',2),'base64') then raise exception '전송 번호의 사진이 일치하지 않습니다.';end if;$patch$);
  src:=replace(src,E' return result;\n elsif p_action=',$patch$
 if p_data->>'photo' is not null then
 insert into omg_private.staff_chat_photos(message_id,image_bytes) values((result->>'message_id')::uuid,decode(split_part(p_data->>'photo',',',2),'base64'));
 end if;
 return result;
 elsif p_action=$patch$);
  if position('insert into omg_private.staff_chat_photos' in src)=0 then raise exception 'Photo insert patch failed';end if;
  src:=replace(src,'to_jsonb(page) order by created_at,id',$patch$to_jsonb(page)||jsonb_build_object('photo',(select 'data:image/jpeg;base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'') from omg_private.staff_chat_photos f where f.message_id=page.id)) order by created_at,id$patch$);
  execute src;
 end if;
 src:=pg_get_functiondef('public.get_guest_chat_dispatch(uuid)'::regprocedure);
 src:=replace(src,'''현장 게스트에게 새 메시지가 왔습니다. 채팅방을 확인해주세요.''',$patch$coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.')$patch$);
 src:=replace(src,'''sender_label'',''현장 게스트''','''sender_label'',r.guest_name');
 execute src;
end $migration$;
commit;
select 'chat photos and message previews ready' as migration_status;
