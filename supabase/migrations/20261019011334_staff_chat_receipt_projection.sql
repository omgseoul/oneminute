begin;

-- Piggyback only requested outgoing read timestamps onto the existing messages poll.
-- Reuse its session, actor and peer authorization, and never mark a message read here.
do $patch$
declare src text;old_part text;new_part text;
begin
 src:=pg_get_functiondef('public.staff_chat_rpc(uuid,text,jsonb)'::regprocedure);
 old_part:=$old$ with page as(select * from omg_private.staff_conversation_items(actor)i where i.peer=peerkey$old$;
 new_part:=$new$ if jsonb_typeof(coalesce(p_data->'receipt_ids','[]'::jsonb))<>'array' then
  raise exception '읽음 확인 목록이 올바르지 않습니다.';
 end if;
 if jsonb_array_length(coalesce(p_data->'receipt_ids','[]'::jsonb))>200 then
  raise exception '한 번에 200개까지 읽음 상태를 확인할 수 있습니다.';
 end if;
 select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids
 from jsonb_array_elements_text(coalesce(p_data->'receipt_ids','[]'::jsonb));
 with page as(select * from omg_private.staff_conversation_items(actor)i where i.peer=peerkey$new$;
 if position(old_part in src)=0 then raise exception 'Unexpected staff chat page projection';end if;
 src:=replace(src,old_part,new_part);
 old_part:=$old$'messages',items);$old$;
 new_part:=$new$'messages',items,'receipts',coalesce((
  select jsonb_agg(jsonb_build_object('id',i.id,'read_at',i.read_at) order by i.created_at,i.id)
  from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and i.mine and i.id=any(ids)
 ),'[]'::jsonb));$new$;
 if position(old_part in src)=0 then raise exception 'Unexpected staff chat messages response';end if;
 src:=replace(src,old_part,new_part);execute src;
end
$patch$;

commit;
