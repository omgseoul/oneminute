begin;
do $patch$
declare definition text;
begin
 definition:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);
 if position('p_action=''inventory''' in definition)=0 then
  definition:=replace(definition,'elsif p_action=''connect'' then',
   'elsif p_action=''inventory'' then
  update omg_private.online_connections set properties=p_data->''properties'' where property_id=p_property;
 elsif p_action=''connect'' then');
  if position('p_action=''inventory''' in definition)=0 then raise exception 'Inventory patch target missing';end if;
  execute definition;
 end if;
end $patch$;
commit;
