begin;
set local jit=off;
do $test$
declare
 biz uuid:=gen_random_uuid();home uuid:=gen_random_uuid();shared uuid:=gen_random_uuid();other uuid:=gen_random_uuid();
 owner_id uuid:=gen_random_uuid();remote_owner uuid:=gen_random_uuid();worker_id uuid:=gen_random_uuid();home_worker uuid:=gen_random_uuid();
 token uuid:=gen_random_uuid();staff_token uuid:=gen_random_uuid();share_id uuid:=gen_random_uuid();mid uuid;other_mission uuid:=gen_random_uuid();
 answer jsonb;payload jsonb;kind text;prop uuid;created_kind text;due timestamptz;listed jsonb;before_title text;
begin
 insert into public.businesses(id,name,code) values(biz,'Mission permission fixture','mission-'||biz);
 insert into public.properties(id,business_id,name,code,service_status,billing_exempt)
 values(home,biz,'Home','mission-'||home,'active',true),(shared,biz,'Shared','mission-'||shared,'active',true),(other,biz,'Unrelated','mission-'||other,'active',true);
 insert into public.owners(id,business_id,property_id,display_name,login_id,pin_hash)
 values(owner_id,biz,home,'Home admin','mission-'||owner_id,'fixture'),(remote_owner,biz,shared,'Shared admin','mission-'||remote_owner,'fixture');
 insert into public.employees(id,business_id,property_id,display_name) values(worker_id,biz,shared,'Shared worker'),(home_worker,biz,home,'Home worker');
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
 values(owner_id,biz,home,omg_private.token_hash(token),now()+interval '1 hour');
 insert into public.work_sessions(employee_id,business_id,property_id,shift,login_token_hash,token_expires_at)
 values(worker_id,biz,shared,'general',omg_private.token_hash(staff_token),now()+interval '1 hour');
 insert into public.property_share_requests(id,requester_property_id,target_property_id,requester_owner_id,requested_permissions,status)
 values(share_id,home,shared,owner_id,array['missions'],'approved');
 -- Own and approved shared missions, including staff-created work, in every date group.
 foreach prop in array array[home,shared] loop
  foreach kind in array array['overdue','today','this_week','anytime'] loop
   due:=now()+case kind when 'overdue' then interval '-2 days' when 'today' then interval '1 hour' when 'this_week' then interval '4 days' else interval '20 days' end;
   insert into public.missions(business_id,property_id,title,due_at,timing,creator_type,creator_employee_id,target_employee_ids)
   values(biz,prop,kind,due,case when kind='overdue' then 'today' else kind end,case when prop=shared then 'staff' else 'owner' end,case when prop=shared then worker_id end,
     jsonb_build_array(case when prop=shared then worker_id else home_worker end)) returning id into mid;
   listed:=public.list_shared_missions(token,array[home,shared]);
   if not exists(select 1 from jsonb_array_elements(listed->'missions') m where m->>'id'=mid::text and (m->>'can_manage')::boolean) then raise exception 'Missing management capability for %',kind;end if;
   payload:=jsonb_build_object('id',mid,'title',kind||' edited','description','Preserved shared assignment','timing','today','priority','normal','target_employee_ids',jsonb_build_array(case when prop=shared then worker_id else home_worker end),'completion_mode','all');
   answer:=public.save_mission(token,payload);
   if not coalesce((answer->>'ok')::boolean,false) or (select title from public.missions where id=mid)<>kind||' edited' then raise exception 'Edit failed for %: %',kind,answer;end if;
   if (select property_id from public.missions where id=mid)<>prop then raise exception 'Mission moved to another property';end if;
   answer:=public.complete_mission(token,mid);
   if not coalesce((answer->>'ok')::boolean,false) or not exists(select 1 from public.missions where id=mid and owner_completed_at is not null and owner_completed_by=owner_id) then raise exception 'Owner completion attribution failed: %',answer;end if;
   answer:=public.archive_mission(token,mid);
   if not coalesce((answer->>'ok')::boolean,false) or (select active from public.missions where id=mid) then raise exception 'Archive failed: %',answer;end if;
  end loop;
 end loop;
 insert into public.missions(id,business_id,property_id,title,target_employee_ids) values(other_mission,biz,other,'Protected task','[]');
 answer:=public.save_mission(token,payload||jsonb_build_object('id',other_mission));if (answer->>'ok')::boolean then raise exception 'Unrelated update allowed';end if;
 answer:=public.complete_mission(token,other_mission);if (answer->>'ok')::boolean then raise exception 'Unrelated completion allowed';end if;
 answer:=public.archive_mission(token,other_mission);if (answer->>'ok')::boolean then raise exception 'Unrelated archive allowed';end if;
 insert into public.missions(business_id,property_id,title,target_employee_ids,photo_required)
 values(biz,shared,'Assigned worker task',jsonb_build_array(worker_id),true) returning id into mid;
 payload:=jsonb_build_object('id',mid,'title','Updated','description','','timing','today','target_employee_ids',jsonb_build_array(worker_id));
 -- Home employees must not become assignees of a different property's mission.
 answer:=public.save_mission(token,payload||jsonb_build_object('target_employee_ids',jsonb_build_array(home_worker)));
 if (answer->>'ok')::boolean or answer->>'code'<>'invalid_target' then raise exception 'Cross-property target accepted: %',answer;end if;
 -- Wrong scope, pending/rejected/revoked sharing must never authorize writes.
 foreach kind in array array['pending','rejected','wrong_scope'] loop
  update public.property_share_requests set status=case when kind='wrong_scope' then 'approved' else kind end,requested_permissions=case when kind='wrong_scope' then array['attendance'] else array['missions'] end where id=share_id;
  answer:=public.save_mission(token,payload);if (answer->>'ok')::boolean then raise exception '% sharing allowed edit',kind;end if;
  answer:=public.complete_mission(token,mid);if (answer->>'ok')::boolean then raise exception '% sharing allowed complete',kind;end if;
  answer:=public.archive_mission(token,mid);if (answer->>'ok')::boolean then raise exception '% sharing allowed archive',kind;end if;
 end loop;
 update public.property_share_requests set status='approved',requested_permissions=array['missions'] where id=share_id;
 answer:=public.save_mission(staff_token,payload);if (answer->>'ok')::boolean then raise exception 'Staff edit allowed';end if;
 answer:=public.archive_mission(staff_token,mid);if (answer->>'ok')::boolean then raise exception 'Staff archive allowed';end if;
 answer:=public.complete_mission(staff_token,mid,'Worker note','');if (answer->>'ok')::boolean or answer->>'code'<>'photo_required' then raise exception 'Worker photo validation changed';end if;
 answer:=public.complete_mission(staff_token,mid,'Worker note','data:image/jpeg;base64,AAAA');if not (answer->>'ok')::boolean then raise exception 'Assigned staff completion blocked: %',answer;end if;
 update public.owner_sessions set token_expires_at=now()-interval '1 minute' where login_token_hash=omg_private.token_hash(token);
 answer:=public.save_mission(token,payload);if (answer->>'ok')::boolean then raise exception 'Expired owner edit accepted';end if;
 answer:=public.complete_mission(token,mid);if (answer->>'ok')::boolean then raise exception 'Expired owner complete accepted';end if;
 answer:=public.archive_mission(token,mid);if (answer->>'ok')::boolean then raise exception 'Expired owner archive accepted';end if;
end $test$;
select 'PASS: all date buckets, own/shared staff-created mission actions, stable property/assignees, owner attribution, unrelated/pending/rejected/wrong-scope/expired denial, worker restrictions and photo completion' result;
rollback;
