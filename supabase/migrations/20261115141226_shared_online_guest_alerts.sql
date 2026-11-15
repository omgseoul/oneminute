-- Ordinary guest messages must reach approved shared-property managers too.
-- Preserve each property's saved scope, time, duty and strength preferences.
-- Existing notices are not replayed or backfilled.
do $patch$
declare f text;old_text text;new_text text;begin
 f:=pg_get_functiondef('omg_private.online_message_alert_recipients(uuid,bigint,timestamptz)'::regprocedure);
 if strpos(f,'omg_private.booking_alert_owners(prop)')=0 then
  old_text:=$old$select 'owner:'||o.id,'owner'::text,o.id,null::uuid,cfg->'owner'->>'mode' from public.owners o where o.property_id=prop and o.active$old$;
  new_text:=$new$select 'owner:'||o.owner_id,'owner'::text,o.owner_id,null::uuid,cfg->'owner'->>'mode' from omg_private.booking_alert_owners(prop) o$new$;
  if strpos(f,old_text)=0 then raise exception 'Online guest recipient definition changed';end if;
  execute replace(f,old_text,new_text);
 end if;
 f:=pg_get_functiondef('public.get_online_push_dispatch(uuid)'::regprocedure);
 if strpos(f,'select ao.topic from omg_private.booking_alert_owners(m.property_id) ao')=0 then
  old_text:=$old$'property_'||m.management_number||case when t.recipient_type='owner' then '_owner_'||t.owner_id else '_employee_'||t.employee_id end topic$old$;
  new_text:=$new$case when t.recipient_type='owner' then (select ao.topic from omg_private.booking_alert_owners(m.property_id) ao where ao.owner_id=t.owner_id) else 'property_'||m.management_number||'_employee_'||t.employee_id end topic$new$;
  if strpos(f,old_text)=0 then raise exception 'Online guest dispatch definition changed';end if;
  execute replace(f,old_text,new_text);
 end if;
end $patch$;
