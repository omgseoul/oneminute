begin;
alter table omg_private.iot_connections add column pin_length_secondary int check(pin_length_secondary between 4 and 9);
-- Existing settings retain their effective secondary length on upgrade.
update omg_private.iot_connections set pin_length_secondary=pin_length;
alter table omg_private.iot_connections alter column pin_length_secondary set not null;
alter table omg_private.iot_connections alter column pin_length_secondary set default 4;
do $migration$
declare f text;old_text text:='pin_length=(p_data->>''pin_length'')::int,';
begin
 f:=pg_get_functiondef('omg_private.iot_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,old_text)=0 then raise exception 'IOT owner definition changed';end if;
 f:=replace(f,old_text,'pin_length=(p_data->>''pin_length'')::int,pin_length_secondary=case when p_data ? ''pin_length_secondary'' then (p_data->>''pin_length_secondary'')::int else c.pin_length_secondary end,');
 execute f;
end$migration$;
commit;
