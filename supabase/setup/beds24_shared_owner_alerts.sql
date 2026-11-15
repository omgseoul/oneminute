-- Same-day bookings notify every active manager with direct message access.
-- Route to the recipient's home property topic, not the booking property's topic.
-- Approved shares are directional; unrelated and revoked properties stay excluded.
create or replace function omg_private.booking_alert_owners(prop uuid)
returns table(owner_id uuid,topic text)
language sql stable security invoker set search_path='' as $$
 select o.id,'property_'||p.management_number||'_owner_'||o.id
 from public.owners o join public.properties p on p.id=o.property_id
 where o.active and (o.property_id=prop or exists(
  select 1 from public.property_share_requests r
  where r.requester_property_id=o.property_id and r.target_property_id=prop
   and r.status='approved' and 'messages'=any(r.requested_permissions)
 ))
$$;
revoke all on function omg_private.booking_alert_owners(uuid) from public,anon,authenticated;
grant execute on function omg_private.booking_alert_owners(uuid) to service_role;

do $patch$
declare f text;old_text text;new_text text;begin
 f:=pg_get_functiondef('omg_private.online_same_day_notice()'::regprocedure);
 if strpos(f,'omg_private.booking_alert_owners(new.property_id)')=0 then
  old_text:=$old$select notice,'owner:'||o.id,'owner',o.id,null from public.owners o where o.property_id=new.property_id and o.active and coalesce((cfg->>'notify_owner')::boolean,false)$old$;
  new_text:=$new$select notice,'owner:'||o.owner_id,'owner',o.owner_id,null from omg_private.booking_alert_owners(new.property_id) o where coalesce((cfg->>'notify_owner')::boolean,false)$new$;
  if strpos(f,old_text)=0 then raise exception 'Same-day booking recipient definition changed';end if;
  execute replace(f,old_text,new_text);
 end if;

 f:=pg_get_functiondef('public.get_online_push_dispatch(uuid)'::regprocedure);
 if strpos(f,'omg_private.booking_alert_owners(m.property_id)')=0 then
  old_text:=$old$select 'property_'||m.management_number||'_owner_'||r.owner_id topic,cfg->>'owner_mode' mode from public.property_message_recipients r join public.owners o on o.id=r.owner_id where r.message_id=m.id and r.recipient_type='owner' and o.active and o.property_id=m.property_id and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_owner')::boolean,false)$old$;
  new_text:=$new$select o.topic,cfg->>'owner_mode' mode from public.property_message_recipients r join omg_private.booking_alert_owners(m.property_id) o on o.owner_id=r.owner_id where r.message_id=m.id and r.recipient_type='owner' and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_owner')::boolean,false)$new$;
  if strpos(f,old_text)=0 then raise exception 'Same-day booking dispatch definition changed';end if;
  execute replace(f,old_text,new_text);
 end if;
end $patch$;
