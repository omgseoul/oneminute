-- Bounded, permission-checked downloads expose the exact size before any media
-- bytes, so clients can report real progress even when HTTP is compressed.
create function omg_private.staff_chat_download(p_access_token uuid,p_action text,p_data jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare actor text;target_peer text:=p_data->>'peer';mid uuid:=(p_data->>'message_id')::uuid;
 gid uuid;size integer;mime text;part integer;chunk text;
begin
 actor:=omg_private.guest_actor(p_access_token)->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action not in('download_info','download_part') or mid is null then raise exception '잘못된 요청입니다.';end if;
 if target_peer like 'group:%' then
  gid:=substring(target_peer from 7)::uuid;
  if not exists(select 1 from omg_private.staff_group_members m where m.group_id=gid and m.actor_key=actor and m.left_at is null)
     or not exists(select 1 from omg_private.staff_group_messages m where m.group_id=gid and m.message_id=mid)
  then raise exception '대화 첨부 파일에 접근할 수 없습니다.';end if;
 elsif not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=target_peer and i.id=mid) then
  raise exception '대화 첨부 파일에 접근할 수 없습니다.';
 end if;
 select octet_length(f.image_bytes),f.mime_type into size,mime from omg_private.staff_chat_photos f where f.message_id=mid;
 if size is null or size not between 3 and 20971520 or mime not in('image/jpeg','video/mp4','video/webm') then raise exception '첨부 파일을 찾을 수 없습니다.';end if;
 if p_action='download_info' then return jsonb_build_object('ok',true,'byte_length',size,'part_size',1048576,'mime_type',mime);end if;
 part:=(p_data->>'part_index')::integer;
 if part is null or part<0 or part>=(size+1048575)/1048576 then raise exception '파일 범위를 확인해주세요.';end if;
 select replace(encode(substring(f.image_bytes from part*1048576+1 for 1048576),'base64'),chr(10),'') into chunk from omg_private.staff_chat_photos f where f.message_id=mid;
 return jsonb_build_object('ok',true,'part_index',part,'byte_length',size,'mime_type',mime,'chunk',chunk);
end $$;
revoke all on function omg_private.staff_chat_download(uuid,text,jsonb) from public,anon,authenticated;

-- Keep the existing public entry point, session checks, and grants intact.
do $$declare src text;needle text:=' if p_action=''create_group'' or peerkey like ''group:%'' then';begin
 src:=pg_get_functiondef('public.staff_chat_rpc(uuid,text,jsonb)'::regprocedure);
 if position(needle in src)=0 then raise exception 'staff_chat_rpc dispatch changed';end if;
 src:=replace(src,needle,E' if p_action in (''download_info'',''download_part'') then return omg_private.staff_chat_download(p_access_token,p_action,p_data);end if;\n'||needle);
 execute src;
end $$;
