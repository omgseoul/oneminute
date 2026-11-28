begin;
-- Prefer Beds24's authoritative source ID. Legacy cache rows still have apiSource.
create function omg_private.online_is_direct(data jsonb,channel text default null) returns boolean language sql immutable set search_path='' as $$
 select case when btrim(coalesce(data->>'apiSourceId','')) ~ '^[0-9]+$' then btrim(data->>'apiSourceId') ~ '^0+$'
 else regexp_replace(lower(coalesce(nullif(btrim(data->>'apiSource'),''),nullif(btrim(channel),''),nullif(btrim(data->>'referer'),''),'')),'[[:space:]_-]+','','g')
  ~ '^(direct(booking)?|manual(booking)?|직접(예약)?|다이렉트(예약)?)$' end
$$;

create function omg_private.auto_message_exclude_direct() returns void language plpgsql security definer set search_path='' as $$begin
 -- Cancel only work that has not reached the provider. Preserve sent/uncertain evidence.
 update omg_private.auto_message_deliveries d set status='skipped',error='다이렉트 예약 · 자동메시지 제외',lease=null,leased_until=null,updated_at=now()
 from omg_private.online_bookings b where b.property_id=d.property_id and b.id=d.booking_id and omg_private.online_is_direct(b.data,b.channel) and d.status in('waiting','preparing','failed');
 update omg_private.auto_message_followups f set status='ignored',actor='system:direct_exclusion',resolved_at=now(),updated_at=now()
 from omg_private.online_bookings b where b.property_id=f.property_id and b.id=f.booking_id and omg_private.online_is_direct(b.data,b.channel) and f.status in('open','planned');
 -- Retain history; clear pending popups/unread badges for the now-excluded alerts.
 update public.property_message_recipients r set read_at=now() where r.read_at is null and r.message_id in(
  select n.message_id from omg_private.online_booking_notices n join omg_private.online_bookings b on b.property_id=n.property_id and b.id=n.booking_id where omg_private.online_is_direct(b.data,b.channel)
  union select n.message_id from omg_private.auto_message_notices n join omg_private.auto_message_deliveries d on d.id=n.delivery_id join omg_private.online_bookings b on b.property_id=d.property_id and b.id=d.booking_id where omg_private.online_is_direct(b.data,b.channel)
  union select n.message_id from omg_private.auto_message_reminders n join omg_private.auto_message_followups f on f.delivery_id=n.delivery_id join omg_private.online_bookings b on b.property_id=f.property_id and b.id=f.booking_id where omg_private.online_is_direct(b.data,b.channel));
end$$;

do $patch$ declare f text;old text;begin
 -- Block all auto-message notice types, including unsupported-channel failures and skips.
 f:=pg_get_functiondef('omg_private.auto_message_notice(uuid,text)'::regprocedure);
 old:=' perform omg_private.auto_message_notice_before_followups(p_delivery,p_kind);';
 if strpos(f,old)=0 then raise exception 'Missing follow-up notice hook';end if;
 execute replace(f,old,$n$ if exists(select 1 from omg_private.auto_message_deliveries direct_delivery join omg_private.online_bookings direct_booking on direct_booking.property_id=direct_delivery.property_id and direct_booking.id=direct_delivery.booking_id where direct_delivery.id=p_delivery and omg_private.online_is_direct(direct_booking.data,direct_booking.channel)) then return;end if;
$n$||old);

 f:=pg_get_functiondef('omg_private.auto_message_scan()'::regprocedure);
 old:='begin perform omg_private.auto_message_followup_scan();';
 if strpos(f,old)=0 then raise exception 'Missing follow-up scan hook';end if;
 f:=replace(f,old,'begin perform omg_private.auto_message_exclude_direct(); perform omg_private.auto_message_followup_scan();');
 old:=$n$where r.enabled and b.status in('new','confirmed')$n$;
 if strpos(f,old)=0 then raise exception 'Missing automatic scheduling filter';end if;
 execute replace(f,old,old||' and not omg_private.online_is_direct(b.data,b.channel)');

 -- A worker with an earlier lease must re-check fresh provider data before sending.
 f:=pg_get_functiondef('omg_private.auto_message_internal(text,jsonb)'::regprocedure);
 old:=$n$ if p_action='prepare' then$n$;
 if strpos(f,old)=0 then raise exception 'Missing final send gate';end if;
 execute replace(f,old,$n$ if p_action in('prepare','exclude_direct','finish') and j.status='preparing' and exists(select 1 from omg_private.online_bookings direct_booking where direct_booking.property_id=j.property_id and direct_booking.id=j.booking_id and omg_private.online_is_direct(direct_booking.data,direct_booking.channel)) then
  update omg_private.auto_message_deliveries set status='skipped',error='다이렉트 예약 · 자동메시지 제외',lease=null,leased_until=null,updated_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'skip',true,'excluded',true);
 end if;
 if p_action='exclude_direct' then return jsonb_build_object('skip',true);end if;
$n$||old);

 f:=pg_get_functiondef('omg_private.auto_message_owner(uuid,text,jsonb)'::regprocedure);
 old:=$n$   if d.status<>'failed' or expected is distinct from d.retry_count then$n$;
 if strpos(f,old)=0 then raise exception 'Missing targeted retry guard';end if;
 execute replace(f,old,$n$   if exists(select 1 from omg_private.online_bookings b where b.property_id=d.property_id and b.id=d.booking_id and omg_private.online_is_direct(b.data,b.channel)) then
    results:=results||jsonb_build_array(jsonb_build_object('id',d.id,'queued',false,'message','다이렉트 예약은 자동메시지 대상에서 제외됩니다.'));
   elsif d.status<>'failed' or expected is distinct from d.retry_count then$n$);

 -- Suppress a reminder even when the booking source changed after it was queued.
 f:=pg_get_functiondef('omg_private.auto_message_followup_scan()'::regprocedure);
 old:=$n$where status in('open','planned') and next_notice_at<=now()$n$;
 if strpos(f,old)=0 then raise exception 'Missing hourly reminder filter';end if;
 execute replace(f,old,old||' and not exists(select 1 from omg_private.online_bookings b where b.property_id=auto_message_followups.property_id and b.id=auto_message_followups.booking_id and omg_private.online_is_direct(b.data,b.channel))');

 -- Keep the existing Booking Page exclusion, but trust provider IDs over labels.
 f:=pg_get_functiondef('omg_private.online_same_day_notice()'::regprocedure);
 old:=$n$if lower(btrim(coalesce(nullif(btrim(new.channel),''),new.data->>'referer',''))) ~ '^(direct([ _-]+booking)?|booking[ _-]?page|manual([ _-]+booking)?|직접( 예약)?|다이렉트( 예약)?)$' then$n$;
 if strpos(f,old)=0 then raise exception 'Missing same-day source filter';end if;
 execute replace(f,old,$n$if omg_private.online_is_direct(new.data,new.channel) or (case when btrim(coalesce(new.data->>'apiSourceId','')) ~ '^[0-9]+$' then btrim(new.data->>'apiSourceId') ~ '^0*1$'
  else regexp_replace(lower(coalesce(nullif(btrim(new.data->>'apiSource'),''),nullif(btrim(new.channel),''),new.data->>'referer','')),'[[:space:]_-]+','','g')='bookingpage' end) then$n$);

 -- Previously queued native pushes are rechecked at dispatch time.
 f:=pg_get_functiondef('public.get_online_push_dispatch(uuid)'::regprocedure);
 old:=$n$ if m.source='beds24_booking' then$n$;
 if strpos(f,old)=0 then raise exception 'Missing same-day dispatch gate';end if;
 execute replace(f,old,old||$n$
  if exists(select 1 from omg_private.online_booking_notices n join omg_private.online_bookings b on b.property_id=n.property_id and b.id=n.booking_id where n.message_id=m.id and omg_private.online_is_direct(b.data,b.channel)) then
   return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'recipient_topics','[]'::jsonb,'recipient_modes','{}'::jsonb);end if;
$n$);
 f:=pg_get_functiondef('omg_private.auto_message_push_dispatch(uuid)'::regprocedure);
 old:=$n$ if exists(select 1 from omg_private.auto_message_followups$n$;
 if strpos(f,old)=0 then raise exception 'Missing automatic notice dispatch gate';end if;
 f:=overlay(f placing $n$ if exists(select 1 from omg_private.auto_message_deliveries d join omg_private.online_bookings b on b.property_id=d.property_id and b.id=d.booking_id
  where omg_private.online_is_direct(b.data,b.channel) and (exists(select 1 from omg_private.auto_message_notices n where n.delivery_id=d.id and n.message_id=m.id) or exists(select 1 from omg_private.auto_message_reminders n where n.delivery_id=d.id and n.message_id=m.id))) then
  return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'recipient_topics','[]'::jsonb,'recipient_modes','{}'::jsonb);end if;
$n$ from strpos(f,old) for 0);execute f;

 f:=pg_get_functiondef('omg_private.pin_delivery_state(uuid,bigint,boolean)'::regprocedure);
 old:=' return v;';if strpos(f,old)=0 then raise exception 'Missing password state hook';end if;
 execute replace(f,old,$n$ if exists(select 1 from omg_private.online_bookings b where b.property_id=prop and b.id=bid and omg_private.online_is_direct(b.data,b.channel)) then
  v:=v||jsonb_build_object('active',false,'due_at',null,'state',case when v->>'state'='sent' then 'sent' else 'excluded' end,'reason','direct');end if;
$n$||old);
end$patch$;
revoke all on function omg_private.online_is_direct(jsonb,text),omg_private.auto_message_exclude_direct() from public,anon,authenticated;
select omg_private.auto_message_exclude_direct();
commit;
