-- Match conversation unread semantics without changing any messages or read receipts.
begin;
do $migration$
declare definition text;old_filter text := $old$r.recipient_key=a->>'key' and r.read_at is null and coalesce(m.source,'')<>'beds24' and coalesce(m.message_type,'')<>'guest_chat'$old$;
 new_filter text := $new$r.recipient_key=a->>'key' and r.read_at is null and coalesce(m.source,'')<>'beds24' and coalesce(m.message_type,'')<>'guest_chat' and (case m.sender_type when 'owner' then 'owner:'||m.sender_owner_id when 'staff' then 'employee:'||m.sender_employee_id else '' end) is distinct from a->>'key'$new$;
begin
 definition:=pg_get_functiondef('omg_private.guest_message_summary(uuid,jsonb)'::regprocedure);
 if position(new_filter in definition)>0 then return;end if;
 if position(old_filter in definition)=0 then raise exception 'Guest summary unread predicate changed';end if;
 execute replace(definition,old_filter,new_filter);
end $migration$;
commit;
