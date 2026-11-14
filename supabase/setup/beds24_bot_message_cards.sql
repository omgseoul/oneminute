-- Presentation metadata only, after existing session and recipient filters.
-- Preserve message bodies, order, recipient access, read state and push delivery.
do $patch$
declare f text;anchor text:='jsonb_build_object(''message_id'',m.id,''property_id'',m.property_id';addition text;begin
 f:=pg_get_functiondef('public.list_notification_bot_messages(uuid,timestamptz,uuid)'::regprocedure);
 addition:=anchor||',''guest_context'',case when m.source=''beds24'' then omg_private.guest_popup_online(m.property_id,m.id) else null end';
 if strpos(f,'''guest_context''')=0 then
  if strpos(f,anchor)=0 then raise exception 'Bot message presentation anchor changed';end if;
  execute replace(f,anchor,addition);
 elsif strpos(f,addition)=0 then raise exception 'Bot guest context definition differs';end if;
end $patch$;
