begin;

-- Keep chat attachments private while allowing videos compressed by the existing browser codec.
alter table omg_private.staff_chat_photos
  drop constraint if exists staff_chat_photos_image_bytes_check;
alter table omg_private.staff_chat_photos
  add constraint staff_chat_photos_image_bytes_check
  check (octet_length(image_bytes) between 3 and 20971520);
alter table omg_private.staff_chat_photos
  add column if not exists mime_type text not null default 'image/jpeg';
alter table omg_private.staff_chat_photos
  drop constraint if exists staff_chat_photos_mime_type_check;
alter table omg_private.staff_chat_photos
  add constraint staff_chat_photos_mime_type_check
  check (mime_type in ('image/jpeg','video/webm'));

do $migration$
declare src text;old_part text;new_part text;
begin
  src:=pg_get_functiondef('public.staff_chat_rpc(uuid,text,jsonb)'::regprocedure);

  old_part:=$find$if p_data->>'photo' is not null then
  if length(p_data->>'photo')>1398127 or p_data->>'photo' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$' then raise exception '1MB 이하 JPEG 사진만 보낼 수 있습니다.';end if;
  if substring(decode(split_part(p_data->>'photo',',',2),'base64') from 1 for 3)<>decode('ffd8ff','hex') then raise exception '올바른 JPEG 사진이 아닙니다.';end if;
 end if;
 client:=(p_data$find$;
  new_part:=$put$if p_data->>'photo' is not null then
  if (p_data->>'photo' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$'
      and p_data->>'photo' !~ '^data:video/webm;base64,[A-Za-z0-9+/]+={0,2}$')
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
 end if;
 client:=(p_data$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat attachment validation';end if;
  src:=replace(src,old_part,new_part);

  old_part:=$find$if (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 decode(split_part(p_data->>'photo',',',2),'base64') then raise exception '전송 번호의 사진이 일치하지 않습니다.';end if;$find$;
  new_part:=$put$if (select image_bytes from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 decode(split_part(p_data->>'photo',',',2),'base64')
 or (select mime_type from omg_private.staff_chat_photos where message_id=old.message_id) is distinct from
 split_part(split_part(p_data->>'photo',':',2),';',1) then raise exception '전송 번호의 첨부 파일이 일치하지 않습니다.';end if;$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat retry validation';end if;
  src:=replace(src,old_part,new_part);

  old_part:=$find$if p_data->>'photo' is not null then
 insert into omg_private.staff_chat_photos(message_id,image_bytes) values((result->>'message_id')::uuid,decode(split_part(p_data->>'photo',',',2),'base64'));
 end if;$find$;
  new_part:=$put$if p_data->>'photo' is not null then
 insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type)
 values((result->>'message_id')::uuid,decode(split_part(p_data->>'photo',',',2),'base64'),
   split_part(split_part(p_data->>'photo',':',2),';',1));
 end if;$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat attachment insert';end if;
  src:=replace(src,old_part,new_part);

  old_part:=$find$to_jsonb(page)||jsonb_build_object('photo',(select 'data:image/jpeg;base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'') from omg_private.staff_chat_photos f where f.message_id=page.id)) order by created_at,id$find$;
  new_part:=$put$to_jsonb(page)||jsonb_build_object(
   'photo',(select case when f.mime_type='image/jpeg' then 'data:image/jpeg;base64,'||replace(encode(f.image_bytes,'base64'),chr(10),'') end from omg_private.staff_chat_photos f where f.message_id=page.id),
   'attachment_type',(select f.mime_type from omg_private.staff_chat_photos f where f.message_id=page.id)) order by created_at,id$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat message projection';end if;
  src:=replace(src,old_part,new_part);

  old_part:=$find$if p_action not in('messages','read','send') then raise exception '잘못된 요청입니다.';end if;$find$;
  new_part:=$put$if p_action not in('messages','read','send','attachment') then raise exception '잘못된 요청입니다.';end if;$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat action list';end if;
  src:=replace(src,old_part,new_part);

  old_part:=$find$ elsif p_action='read' then$find$;
  new_part:=$put$ elsif p_action='attachment' then
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
 elsif p_action='read' then$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected staff chat read action';end if;
  src:=replace(src,old_part,new_part);

  if position('attachment_type' in src)=0 or position('p_action=''attachment''' in src)=0 then
    raise exception 'Staff chat video access patch incomplete';
  end if;
  execute src;
end
$migration$;

-- Charge stored chat media against the same per-property limit as other uploads.
do $migration$
declare src text;old_part text;new_part text;
begin
  src:=pg_get_functiondef('omg_private.property_usage_bytes(uuid)'::regprocedure);
  old_part:=$find$+(select coalesce(sum(octet_length(e.report_config::text)),0) from public.employees e where e.property_id=prop);$find$;
  new_part:=$put$+(select coalesce(sum(octet_length(e.report_config::text)),0) from public.employees e where e.property_id=prop)
 +(select coalesce(sum(octet_length(f.image_bytes)),0) from omg_private.staff_chat_photos f
   join public.property_messages m on m.id=f.message_id where m.property_id=prop);$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected property storage accounting function';end if;
  src:=replace(src,old_part,new_part);
  if position('staff_chat_photos' in src)=0 then raise exception 'Chat video storage accounting patch incomplete';end if;
  execute src;

  src:=pg_get_functiondef('omg_private.guard_service_write()'::regprocedure);
  old_part:=$find$else prop:=new.property_id;end if;$find$;
  new_part:=$put$elsif tg_table_schema='omg_private' and tg_table_name='staff_chat_photos' then
  select property_id into prop from public.property_messages where id=new.message_id;
  has_photo:=true;delta:=octet_length(new.image_bytes);
  if tg_op='UPDATE' then delta:=delta-octet_length(old.image_bytes);end if;
 else prop:=new.property_id;end if;$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected service storage guard';end if;
  src:=replace(src,old_part,new_part);
  old_part:=$find$new.message like '%data:image/%';$find$;
  new_part:=$put$(new.message like '%data:image/%' or new.message like '%data:video/webm;base64,%')$put$;
  if position(old_part in src)=0 then raise exception 'Unexpected property message storage guard';end if;
  src:=replace(src,old_part,new_part);
  if position('staff_chat_photos' in src)=0 or position('data:video/webm' in src)=0 then
    raise exception 'Chat video storage guard patch incomplete';
  end if;
  execute src;
end
$migration$;

drop trigger if exists staff_chat_photos_service_guard on omg_private.staff_chat_photos;
create trigger staff_chat_photos_service_guard
before insert or update on omg_private.staff_chat_photos
for each row execute function omg_private.guard_service_write();

commit;
