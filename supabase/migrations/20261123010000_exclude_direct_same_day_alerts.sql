-- Preserve installed recipient routing while excluding manual bookings.
do $patch$
declare
 definition text := pg_get_functiondef('omg_private.online_same_day_notice()'::regprocedure);
 marker text := ' if tg_op=''UPDATE'' then';
 guard text := $guard$ if lower(btrim(coalesce(nullif(btrim(new.channel),''),new.data->>'referer',''))) ~ '^(direct([ _-]+booking)?|booking[ _-]?page|manual([ _-]+booking)?|직접( 예약)?|다이렉트( 예약)?)$' then
  return new;
 end if;$guard$;
begin
 if strpos(definition,guard)>0 then return;end if;
 if strpos(definition,marker)=0 then raise exception 'Same-day booking trigger definition changed';end if;
 execute replace(definition,marker,guard||chr(10)||marker);
end $patch$;
