-- Reuse the same per-property automatic translation opt-in, exclusions and billed cache.
create or replace function public.online_notice_translation(p_property uuid,p_notice uuid)returns jsonb language sql security definer set search_path='' as $$
 select jsonb_build_object('message_id',m.id) from omg_private.online_messages m join omg_private.online_connections c on c.property_id=m.property_id
 where m.property_id=p_property and m.notice_id=p_notice and m.source='guest' and c.auto_translate limit 1
$$;
revoke all on function public.online_notice_translation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.online_notice_translation(uuid,uuid) to service_role;

create or replace function omg_private.guest_popup_online(prop uuid,notice uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('kind','online','guest',left(coalesce(b.guest_name,'예약 #'||om.booking_id),120),'room',left(coalesce(b.room_name,'객실 미정'),60),'arrival',b.arrival,'departure',b.departure,'property',left(p.name,3),'channel',left(coalesce(b.channel,''),80),'sent',to_char(om.sent_at at time zone coalesce(p.timezone,'Asia/Seoul'),'MM.DD HH24:MI'))
 ||case when translated.translated is not null then jsonb_build_object('translation',translated.translated,'original',om.body,'target',c.incoming_translation_language) else '{}'::jsonb end
 from omg_private.online_messages om join public.properties p on p.id=om.property_id left join omg_private.online_bookings b on b.property_id=om.property_id and b.id=om.booking_id
 left join omg_private.online_connections c on c.property_id=om.property_id
 left join lateral(select j.translated from omg_private.translation_jobs j where j.property_id=om.property_id and j.booking_id=om.booking_id and j.message_id=om.id and j.body=om.body and j.body_hash=md5(om.body) and j.direction='incoming' and j.status='done' and j.target=c.incoming_translation_language and c.auto_translate and j.translated<>om.body and coalesce(omg_private.translation_language(j.source_language),'')<>omg_private.translation_language(c.incoming_translation_language) and not(coalesce(omg_private.translation_language(j.source_language),'')=any(c.translation_excluded_languages)) order by j.updated_at desc limit 1)translated on true
 where om.property_id=$1 and om.notice_id=$2 limit 1
$$;
