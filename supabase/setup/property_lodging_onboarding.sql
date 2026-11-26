begin;
-- Allow an empty room list when a property first chooses lodging. Preserve the
-- existing validators for entered rows, authorization, quotas and grants.
do $migration$
declare signature text;f text;old_validation text:='if omg_private.room_types_are_valid(p_room_types) is not true then';old_update text:='then v_room_types else room_types end';
begin
 foreach signature in array array[
  'public.save_property_settings(uuid,text,jsonb,jsonb,jsonb,text,jsonb)',
  'public.shared_save_property_settings(uuid,uuid,text,jsonb,jsonb,jsonb,text,jsonb)'
 ] loop
  f:=pg_get_functiondef(signature::regprocedure);
  if strpos(f,old_validation)=0 or strpos(f,old_update)=0 then raise exception 'Property settings definition changed: %',signature;end if;
  f:=replace(f,old_validation,'if p_room_types is distinct from ''[]''::jsonb and omg_private.room_types_are_valid(p_room_types) is not true then');
  f:=replace(f,old_update,'then coalesce(v_room_types,''[]''::jsonb) else room_types end');
  execute f;
 end loop;
end$migration$;
commit;
