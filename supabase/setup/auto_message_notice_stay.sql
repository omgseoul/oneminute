begin;
-- Presentation metadata for already-authorized notices, including historical skips.
-- Keep retry eligibility, recipients and scheduling unchanged.
create or replace function omg_private.auto_message_notice_context(p_message uuid,p_property uuid) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('delivery_id',d.id,'retry_count',n.retry_count,'status',d.status,'can_retry',
 d.status='failed' and d.retry_count=n.retry_count and r.enabled,
 'arrival',b.arrival,'departure',b.departure)
 from omg_private.auto_message_notices n
 join omg_private.auto_message_deliveries d on d.id=n.delivery_id
 join omg_private.auto_message_rules r on r.id=d.rule_id
 left join omg_private.online_bookings b on b.property_id=d.property_id and b.id=d.booking_id
 where n.message_id=p_message and d.property_id=p_property and n.kind='terminal'
$$;
revoke all on function omg_private.auto_message_notice_context(uuid,uuid) from public,anon,authenticated;
commit;
