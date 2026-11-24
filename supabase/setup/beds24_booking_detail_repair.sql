begin;
-- Follow explicit connection reuse across later main-account reconnects.
alter table omg_private.online_connections add column if not exists credential_source_property_id uuid references public.properties(id) on delete set null;
create index if not exists online_connections_credential_source_idx on omg_private.online_connections(credential_source_property_id) where credential_source_property_id is not null;
do $repair$
declare definition text; original text;
begin
 definition:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);original:=definition;
 if position('credential_source_property_id=null' in definition)=0 then
  definition:=replace(definition,'set vault_id=sid,properties=', 'set vault_id=sid,credential_source_property_id=null,properties=');
  definition:=replace(definition,
   'insert into omg_private.online_audit(property_id,action,actor)values(p_property,''connected'',p_data->>''actor'');',
   'update omg_private.online_connections set vault_id=sid,properties=coalesce(p_data->''properties'',properties),connected_at=now(),last_error=null where credential_source_property_id=p_property;
  insert into omg_private.online_audit(property_id,action,actor)values(p_property,''connected'',p_data->>''actor'');');
 end if;
 -- Missing keys mean a partial update; explicit null still clears unknown prices.
 definition:=replace(definition,'data=excluded.data,updated_at=now()',
  'data=case when excluded.data ? ''price'' then excluded.data else jsonb_strip_nulls(jsonb_build_object(''price'',omg_private.online_bookings.data->''price'',''currency'',omg_private.online_bookings.data->''currency'')) || excluded.data end,updated_at=now()');
 if position('''password_source''' in definition)=0 then
  definition:=replace(definition,'''ai_mode'',c.ai_mode,''secret'',','''ai_mode'',c.ai_mode,''password_source'',(select source from omg_private.web_checkin_settings where property_id=p_property),''secret'',');
 end if;
 if position('credential_source_property_id=null' in definition)=0 or position('excluded.data ? ''price''' in definition)=0 or position('''password_source''' in definition)=0 then raise exception 'Booking detail patch target missing';end if;
 if definition<>original then execute definition;end if;
 definition:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if position('credential_source_property_id=coalesce' in definition)=0 then
  definition:=replace(definition,'set vault_id=source.vault_id,properties=source.properties,','set vault_id=source.vault_id,credential_source_property_id=coalesce(source.credential_source_property_id,source.property_id),properties=source.properties,');
  if position('credential_source_property_id=coalesce' in definition)=0 then raise exception 'Connection reuse patch target missing';end if;
  execute definition;
 end if;
end $repair$;
commit;
