begin;
do $test$
declare own public.owners%rowtype; ids uuid[]; ot uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); out jsonb; mid uuid; allid uuid; item jsonb;
begin
 select o.* into own from public.owners o where o.active and (select count(*) from public.employees e where e.property_id=o.property_id and e.active and e.role<>'owner')>=2 limit 1;
 if not found then raise exception 'Need a property with two active staff for rollback test'; end if;
 select array_agg(e.id order by e.id) into ids from public.employees e where e.property_id=own.property_id and e.active and e.role<>'owner';
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at) values(own.id,own.business_id,own.property_id,omg_private.token_hash(ot),clock_timestamp()+interval '5 minutes');
 insert into public.work_sessions(business_id,property_id,employee_id,shift,login_token_hash,token_expires_at,status,clock_out_at) values
 (own.business_id,own.property_id,ids[1],'general',omg_private.token_hash(a),clock_timestamp()+interval '5 minutes','completed',clock_timestamp()),
 (own.business_id,own.property_id,ids[2],'general',omg_private.token_hash(b),clock_timestamp()+interval '5 minutes','completed',clock_timestamp());
 out:=public.save_mission(ot,'{"title":"Rollback ANY test","timing":"today","completion_mode":"any","target_employee_ids":[]}'::jsonb);assert (out->>'ok')::boolean,out::text;mid:=(out->>'mission_id')::uuid;
 out:=public.complete_mission(a,mid,'First completed');assert (out->>'ok')::boolean,out::text;
 out:=public.complete_mission(b,mid,'Second completed');assert out->>'code'='already_completed',out::text;
 select j into item from jsonb_array_elements(public.list_missions(b)->'missions') j where j->>'id'=mid::text;
 assert item->>'completion_mode'='any' and (item->>'completed_count')::int=1,item::text;
 assert jsonb_array_length(item->'completions')=1,item::text;
 select j into item from jsonb_array_elements(public.list_shared_missions(ot)->'missions') j where j->>'id'=mid::text;
 assert item->>'completion_mode'='any',item::text;
 out:=public.save_mission(ot,'{"title":"Rollback ALL test","timing":"today","target_employee_ids":[]}'::jsonb);assert (out->>'ok')::boolean,out::text;allid:=(out->>'mission_id')::uuid;
 out:=public.complete_mission(a,allid,'First');assert (out->>'ok')::boolean,out::text;
 out:=public.complete_mission(b,allid,'Second');assert (out->>'ok')::boolean,out::text;
 assert (select count(*) from public.mission_completions where mission_id=allid)=2;
 out:=public.save_mission(a,'{"title":"Invalid staff ANY","timing":"today","completion_mode":"any"}'::jsonb);assert out->>'code'='invalid_completion_mode',out::text;
end;
$test$;
select 'any first completion, repeat rejection, staff/owner listing, all per-person completion and invalid mode passed' as test_result;

rollback;
