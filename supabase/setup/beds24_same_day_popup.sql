-- Same recipient rules and BOT destination; presentation only.
create or replace function omg_private.guest_popup_booking(prop uuid,notice uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('kind','same_day','guest',left(coalesce(b.guest_name,'게스트'),120),'room',left(coalesce(nullif(b.room_name,''),'객실 미정'),60),'arrival',b.arrival,'departure',b.departure,'property',left(p.name,80),'channel',left(coalesce(b.channel,''),80),'sent',to_char(m.created_at at time zone coalesce(p.timezone,'Asia/Seoul'),'MM.DD HH24:MI'))
 from omg_private.online_booking_notices n join omg_private.online_bookings b on b.property_id=n.property_id and b.id=n.booking_id join public.properties p on p.id=n.property_id join public.property_messages m on m.id=n.message_id
 where n.property_id=$1 and n.message_id=$2 limit 1
$$;
revoke all on function omg_private.guest_popup_booking(uuid,uuid) from public,anon,authenticated;
grant execute on function omg_private.guest_popup_booking(uuid,uuid) to service_role;
do $$declare f text;needle text;begin
 f:=pg_get_functiondef('public.get_online_push_dispatch(uuid)'::regprocedure);
 if strpos(f,'guest_popup_booking')=0 then
  needle:=$n$'sender_label','당일 예약'$n$;if strpos(f,needle)=0 then raise exception 'booking dispatch anchor changed';end if;
  f:=replace(f,needle,$n$'guest_context',omg_private.guest_popup_booking(m.property_id,m.id),'sender_label','당일 예약 발생'$n$);execute f;
 end if;
 f:=pg_get_functiondef('public.list_property_messages(uuid)'::regprocedure);
 if strpos(f,'guest_popup_booking')=0 then
  needle:=$n$case when m.source='beds24' then omg_private.guest_popup_online(m.property_id,m.id) else null end$n$;
  if strpos(f,needle)=0 then raise exception 'booking home popup anchor changed';end if;
  execute replace(f,needle,$n$case when m.source='beds24' then omg_private.guest_popup_online(m.property_id,m.id) when m.source='beds24_booking' then omg_private.guest_popup_booking(m.property_id,m.id) else null end$n$);
 end if;
end$$;
