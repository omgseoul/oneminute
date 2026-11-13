-- Add departure-date queries and range-aware staying queries to the authorized read.
do $patch$
declare f text;n text;begin
 f:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,'when ''departure'' then b.departure between v_from and v_to')=0 then
  n:='when ''staying'' then b.arrival<=v_from and b.departure>v_from';
  if strpos(f,n)=0 then raise exception 'Check-in list query anchor changed';end if;
  execute replace(f,n,'when ''departure'' then b.departure between v_from and v_to when ''staying'' then b.arrival<=v_to and b.departure>v_from');
 end if;
end $patch$;
