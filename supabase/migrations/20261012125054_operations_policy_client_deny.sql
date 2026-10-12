create policy service_policy_no_client_access on omg_private.service_policy for all to anon,authenticated using(false) with check(false);
create policy service_plans_no_client_access on omg_private.service_plans for all to anon,authenticated using(false) with check(false);
create policy service_notices_no_client_access on omg_private.service_notices for all to anon,authenticated using(false) with check(false);
