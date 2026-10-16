begin;
do $test$
declare own public.owners%rowtype; eid uuid; other_eid uuid; employee_name text; ot uuid:=gen_random_uuid(); st uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); result jsonb; msg uuid; mid uuid; item jsonb; rec public.property_message_recipients%rowtype; sig boolean; understood boolean; first_at timestamptz;
begin
 select o.* into strict own from public.owners o where o.active and exists(select 1 from public.employees e where e.property_id=o.property_id and e.active and e.role<>'owner') limit 1;
 select e.id,e.display_name into eid,employee_name from public.employees e where e.property_id=own.property_id and e.active and e.role<>'owner' limit 1;
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at) values(own.id,own.business_id,own.property_id,omg_private.token_hash(ot),clock_timestamp()+interval '5 minutes');
 insert into public.work_sessions(business_id,property_id,employee_id,shift,login_token_hash,token_expires_at,status,clock_out_at) values(own.business_id,own.property_id,eid,'general',omg_private.token_hash(st),clock_timestamp()+interval '5 minutes','completed',clock_timestamp());
 foreach sig in array array[false,true] loop
 foreach understood in array array[false,true] loop
  result:=public.send_configured_announcement(ot,array[eid],array[]::uuid[],'[transaction rollback test] notice options',sig,understood);assert (result->>'ok')::boolean,result::text;msg:=(result->>'message_id')::uuid;
  assert (select require_signature=sig and require_understanding=understood from public.property_messages where id=msg);
  result:=public.mark_property_message_read(st,msg);assert (result->>'ok')::boolean=not(sig or understood),result::text;
  if understood then result:=public.acknowledge_announcement(st,msg,employee_name,false);assert result->>'code'='understanding_required',result::text;end if;
  if sig then result:=public.acknowledge_announcement(st,msg,'wrong name',true);assert result->>'code'='name_mismatch',result::text;end if;
  result:=public.acknowledge_announcement(st,msg,case when sig then employee_name else '' end,understood);assert (result->>'ok')::boolean,result::text;
  select * into rec from public.property_message_recipients where message_id=msg and employee_id=eid;
  assert rec.acknowledged_at is not null and rec.read_at is not null;
  assert rec.acknowledged_name is not distinct from case when sig then employee_name else null end;
  assert rec.acknowledged_understood=understood;
  select j into item from jsonb_array_elements(public.list_property_messages(st)->'messages') j where j->>'message_id'=msg::text;
  assert (item->>'require_signature')::boolean=sig and (item->>'require_understanding')::boolean=understood,item::text;
  select j into item from jsonb_array_elements(public.list_notification_bot_messages(st)->'messages') j where j->>'message_id'=msg::text;
  assert (item->>'require_signature')::boolean=sig and (item->>'require_understanding')::boolean=understood,item::text;
 end loop;end loop;
 result:=public.send_configured_announcement(st,array[eid],array[]::uuid[],'forbidden staff notice',false,false);assert result->>'code'='owner_required',result::text;
 result:=public.acknowledge_announcement(outsider,msg,employee_name,true);assert result->>'code'='staff_required',result::text;
 result:=public.send_shared_property_message(ot,array[eid],array[]::uuid[],'legacy signature notice','normal','announcement');assert (result->>'ok')::boolean,result::text;
 assert(select require_signature and require_understanding from public.property_messages where id=(result->>'message_id')::uuid);
 insert into public.missions(business_id,property_id,title,timing,priority,target_employee_ids,photo_required,due_at) values(own.business_id,own.property_id,'[transaction rollback test] owner complete','today','normal',jsonb_build_array(eid),true,clock_timestamp()-interval '1 day') returning id into mid;
 result:=public.complete_mission(outsider,mid);assert not (result->>'ok')::boolean,result::text;
 result:=public.complete_mission(ot,mid);assert (result->>'ok')::boolean and result->>'completed_by'='관리자',result::text;
 select owner_completed_at into first_at from public.missions where id=mid;
 assert first_at is not null and (select owner_completed_by=own.id from public.missions where id=mid);
 assert not exists(select 1 from public.mission_completions where mission_id=mid);
 result:=public.complete_mission(ot,mid);assert (result->>'ok')::boolean and (result->>'completed_at')::timestamptz=first_at,result::text;
 result:=public.complete_mission(st,mid,'late staff');assert result->>'code'='already_completed',result::text;
 select j into item from jsonb_array_elements(public.list_missions(st)->'missions') j where j->>'id'=mid::text;
 assert item->>'owner_completed_at' is not null and item->'completions'->0->>'employee_name'='관리자',item::text;
 select j into item from jsonb_array_elements(public.list_shared_missions(ot)->'missions') j where j->>'id'=mid::text;
 assert item->>'owner_completed_at' is not null and item->'completions'->0->>'completer_type'='owner',item::text;
 assert not exists(select 1 from jsonb_array_elements(public.list_overdue_calendar_tasks(ot)->'tasks') j where j->>'id'=mid::text);
 -- Existing staff completion must still work for tasks not completed by an owner.
 insert into public.missions(business_id,property_id,title,timing,priority,target_employee_ids) values(own.business_id,own.property_id,'[transaction rollback test] staff complete','today','normal',jsonb_build_array(eid)) returning id into mid;
 result:=public.complete_mission(st,mid,'Staff completed');assert (result->>'ok')::boolean,result::text;
 assert (select count(*)=1 from public.mission_completions where mission_id=mid and employee_id=eid);
 assert (select owner_completed_at is null from public.missions where id=mid);
end;
$test$;
select 'PASS: four notice option combinations, required-field enforcement, read receipts, backward compatibility, staff/invalid-session denial, administrator completion, idempotency, late staff rejection, listings/calendar, and existing staff completion' as test_result;
rollback;
