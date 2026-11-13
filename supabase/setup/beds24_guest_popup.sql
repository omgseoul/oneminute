-- Presentation metadata only; preserve recipient eligibility, mode and acknowledgement.
create or replace function omg_private.guest_popup_online(prop uuid,notice uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('kind','online','guest',left(coalesce(b.guest_name,'예약 #'||om.booking_id),120),'room',left(coalesce(b.room_name,'객실 미정'),60),'arrival',b.arrival,'departure',b.departure,'property',left(p.name,3),'channel',left(coalesce(b.channel,''),80),'sent',to_char(om.sent_at at time zone coalesce(p.timezone,'Asia/Seoul'),'MM.DD HH24:MI')) from omg_private.online_messages om join public.properties p on p.id=om.property_id left join omg_private.online_bookings b on b.property_id=om.property_id and b.id=om.booking_id where om.property_id=$1 and om.notice_id=$2 limit 1
$$;
create or replace function omg_private.guest_popup_onsite(room uuid,at_time timestamptz) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('kind','onsite','guest',left(r.guest_name,120),'room',left(coalesce(nullif(r.room_number,''),'객실 미정'),60),'arrival',r.check_in,'departure',r.check_out,'property',left(p.name,3),'channel','','sent',to_char(at_time at time zone coalesce(p.timezone,'Asia/Seoul'),'MM.DD HH24:MI')) from public.guest_chat_rooms r join public.properties p on p.id=r.property_id where r.id=$1
$$;
revoke all on function omg_private.guest_popup_online(uuid,uuid),omg_private.guest_popup_onsite(uuid,timestamptz) from public,anon,authenticated;
grant execute on function omg_private.guest_popup_online(uuid,uuid),omg_private.guest_popup_onsite(uuid,timestamptz) to service_role;
do $patch$
declare f text;n text;begin
 f:=pg_get_functiondef('public.get_online_push_dispatch(uuid)'::regprocedure);
 if strpos(f,'''guest_context''')=0 then
  n:='''recipient_modes'',modes,''route'',''online.html#thread/''';if strpos(f,n)=0 then raise exception 'Online guest dispatch anchor changed';end if;
  execute replace(f,n,'''recipient_modes'',modes,''guest_context'',omg_private.guest_popup_online(m.property_id,m.id),''route'',''online.html#thread/''');
 end if;
 f:=pg_get_functiondef('public.get_guest_chat_dispatch(uuid)'::regprocedure);
 if strpos(f,'''guest_context''')=0 then
  n:='''message_type'',''guest_chat'',';if strpos(f,n)=0 then raise exception 'Onsite guest dispatch anchor changed';end if;
  execute replace(f,n,n||'''guest_context'',omg_private.guest_popup_onsite(r.id,ev.created_at),');
 end if;
 f:=pg_get_functiondef('public.list_property_messages(uuid)'::regprocedure);
 if strpos(f,'''guest_context''')=0 then
  n:='jsonb_build_object(''message_id'',m.id,''property_id'',m.property_id';if strpos(f,n)=0 then raise exception 'Home guest presentation anchor changed';end if;
  execute replace(f,n,n||',''guest_context'',case when m.source=''beds24'' then omg_private.guest_popup_online(m.property_id,m.id) else null end');
 end if;
end $patch$;
