begin;
-- Restore staff chat photo handling after later RPC replacements kept the photo table but dropped the code.
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
  if position('insert into omg_private.staff_chat_photos' in src)=0 or position('jsonb_build_object(''photo''' in src)=0 then raise exception 'Photo patch incomplete';end if;
  execute src;
 end if;
end $migration$;
commit;
