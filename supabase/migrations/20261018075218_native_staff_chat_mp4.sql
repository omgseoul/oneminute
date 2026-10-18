begin;

alter table omg_private.staff_chat_photos drop constraint if exists staff_chat_photos_mime_type_check;
alter table omg_private.staff_chat_photos add constraint staff_chat_photos_mime_type_check
 check(mime_type in ('image/jpeg','video/webm','video/mp4'));

do $patch$
declare src text;old_part text;new_part text;
begin
 src:=pg_get_functiondef('public.staff_chat_rpc(uuid,text,jsonb)'::regprocedure);
 old_part:=$old$and p_data->>'photo' !~ '^data:video/webm;base64,[A-Za-z0-9+/]+={0,2}$')$old$;
 new_part:=$new$and p_data->>'photo' !~ '^data:video/webm;base64,[A-Za-z0-9+/]+={0,2}$'
      and p_data->>'photo' !~ '^data:video/mp4;base64,[A-Za-z0-9+/]+={0,2}$')$new$;
 if position(old_part in src)=0 then raise exception 'Unexpected staff chat MIME validation';end if;
 src:=replace(src,old_part,new_part);
 old_part:=$old$   raise exception '올바른 WebM 동영상이 아닙니다.';
  end if;$old$;
 new_part:=$new$   raise exception '올바른 WebM 동영상이 아닙니다.';
  end if;
  if p_data->>'photo' like 'data:video/mp4%' and
     (octet_length(decode(split_part(p_data->>'photo',',',2),'base64'))<12
      or substring(decode(split_part(p_data->>'photo',',',2),'base64') from 5 for 4)<>decode('66747970','hex')) then
   raise exception '올바른 MP4 동영상이 아닙니다.';
  end if;$new$;
 if position(old_part in src)=0 then raise exception 'Unexpected staff chat video signature validation';end if;
 src:=replace(src,old_part,new_part);execute src;
end
$patch$;

-- Preserve all existing session/recipient/cursor checks. Images are fetched lazily through
-- the existing permission-checked attachment action rather than decoded 50 at a time.
create or replace function public.staff_chat_native_messages(p_access_token uuid,p_data jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 result:=public.staff_chat_rpc(p_access_token,'messages',p_data);
 return jsonb_set(result,'{messages}',coalesce((select jsonb_agg(item-'photo' order by ordinal)
   from jsonb_array_elements(coalesce(result->'messages','[]'::jsonb)) with ordinality as rows(item,ordinal)),'[]'::jsonb));
end;
$$;
revoke all on function public.staff_chat_native_messages(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.staff_chat_native_messages(uuid,jsonb) to anon,authenticated;

commit;
