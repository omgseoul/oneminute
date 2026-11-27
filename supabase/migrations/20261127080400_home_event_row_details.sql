do $migration$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('public.oms_home_display(uuid,jsonb,boolean)'::regprocedure);
 anchor:=$old$  select coalesce(jsonb_agg(to_jsonb(i) order by i.at_time desc,i.kind,i.target),'[]') into events
    from (select * from items order by at_time desc,kind,target limit 30)i;$old$;
 if strpos(definition,anchor)=0 then raise exception 'Missing home event feed selection';end if;
 execute replace(definition,anchor,$new$  select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object(
    'property_name',p.name,'arrival',b.arrival,'departure',b.departure,'channel',b.channel)
    order by i.at_time desc,i.kind,i.target),'[]') into events
    from (select * from items order by at_time desc,kind,target limit 30)i
    join public.properties p on p.id=property_key
    left join omg_private.online_bookings b on b.property_id=property_key
      and b.id=case when i.kind in ('booking','cancel','online_ai') then i.target::bigint end;$new$);
end $migration$;
