create or replace function omg_private.iot_notice_context(p_message uuid,p_property uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('channel',b.channel,'reference',b.data->>'apiReference','booking_id',b.id,
 'pin',case when n.kind='done' and n.revision=j.revision and j.status='done'
   and j.valid_until>now() and b.status in ('new','confirmed')
   then j.state->>'pin' end)
 from omg_private.iot_notices n join omg_private.iot_jobs j on j.id=n.job_id
 join omg_private.online_bookings b on b.property_id=j.property_id and b.id=j.booking_id
 where n.message_id=p_message and j.property_id=p_property
$$;
