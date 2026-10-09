-- Keep saved employee alert choices intact. New employees and older accounts
-- without a preference start with notifications enabled at the strong level.
create or replace function omg_private.ensure_employee_chat_alert_defaults()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_rule_id uuid := gen_random_uuid();
begin
  if new.active and new.role <> 'owner' then
    insert into public.guest_chat_alert_preferences
      (actor_key, home_property_id, enabled, property_ids, days, start_time, end_time, alert_mode, schedules)
    values
      ('employee:' || new.id, new.property_id, true, array[new.property_id],
       array[0,1,2,3,4,5,6], null, null, 'strong',
       jsonb_build_array(jsonb_build_object(
         'id', v_rule_id, 'enabled', true, 'alert_mode', 'strong',
         'property_ids', jsonb_build_array(new.property_id),
         'days', jsonb_build_array(0,1,2,3,4,5,6),
         'start_time', '', 'end_time', '')))
    on conflict (actor_key) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists employee_chat_alert_defaults on public.employees;
create trigger employee_chat_alert_defaults
after insert on public.employees
for each row execute function omg_private.ensure_employee_chat_alert_defaults();

insert into public.guest_chat_alert_preferences
  (actor_key, home_property_id, enabled, property_ids, days, start_time, end_time, alert_mode, schedules)
select 'employee:' || e.id, e.property_id, true, array[e.property_id],
       array[0,1,2,3,4,5,6], null, null, 'strong',
       jsonb_build_array(jsonb_build_object(
         'id', gen_random_uuid(), 'enabled', true, 'alert_mode', 'strong',
         'property_ids', jsonb_build_array(e.property_id),
         'days', jsonb_build_array(0,1,2,3,4,5,6),
         'start_time', '', 'end_time', ''))
from public.employees e
where e.active and e.role <> 'owner'
on conflict (actor_key) do nothing;
