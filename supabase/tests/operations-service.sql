-- Transaction-only verification; all fixtures and policy changes are rolled back.
begin;
do $$
declare admin uuid;prop uuid;business uuid;existing timestamptz;result jsonb;one jsonb;two jsonb;path1 text;path2 text;
begin
 if public.platform_operations()->>'ok'<>'false' then raise exception 'Unauthorized access accepted';end if;
 select user_id into admin from public.platform_administrators limit 1;if admin is null then raise exception 'Operator fixture unavailable';end if;
 perform set_config('request.jwt.claim.sub',admin::text,true);
 select trial_ends_at into existing from public.properties where service_status='trial' limit 1;
 one:=jsonb_build_object('trial_days',14,'reminder_days',3,'grace_days',2,'storage_limit_bytes',2147483648,'storage_warning_bytes',1073741824,'end_action','notice','storage_action','warn','support_contact','test','plans',jsonb_build_array(jsonb_build_object('code','basic','name','기본','monthly_price','','storage_limit_bytes',2147483648),jsonb_build_object('code','pro','name','프로','monthly_price',10000,'storage_limit_bytes',5368709120)));
 result:=public.platform_operations('policy',one);if result->'policy'->>'trial_days'<>'14' then raise exception 'Policy save failed';end if;
 if existing is distinct from (select trial_ends_at from public.properties where service_status='trial' limit 1) then raise exception 'Existing trial changed';end if;
 insert into public.businesses(name,code)values('Ops transaction test','ops-test-'||gen_random_uuid())returning id into business;
 insert into public.properties(business_id,name,code,rooms)values(business,'Ops transaction test','ops-test','[]')returning id into prop;
 if (select trial_ends_at from public.properties where id=prop)<now()+interval '13 days' then raise exception 'New trial not snapshotted';end if;
 two:=jsonb_build_object('property_id',prop,'service_plan','pro','service_status','trial','operator_note','test','billing_exempt',false,'trial_ends_at',now()+interval '1 day','subscription_ends_at','','storage_limit_bytes',1048576,'storage_warning_bytes',524288);
 result:=public.platform_operations('customer',two);if (select service_plan from public.properties where id=prop)<>'pro' then raise exception 'Customer save failed';end if;
 if (omg_private.property_service_state(prop)->>'remind')::boolean is not true then raise exception 'Reminder calculation failed';end if;
 update omg_private.service_policy set storage_action='block_photos' where id;
 path1:='ops-test/'||gen_random_uuid();path2:='ops-test/'||gen_random_uuid();
 insert into public.guest_support_assets(property_id,uploader_key,object_path,mime,ready)values(prop,'ops-test',path1,'image/jpeg',false),(prop,'ops-test',path2,'image/jpeg',false);
 insert into storage.objects(bucket_id,name,metadata) values('guest-support',path1,'{"size":600000}'::jsonb);
 begin insert into storage.objects(bucket_id,name,metadata) values('guest-support',path2,'{"size":600000}'::jsonb);raise exception 'Quota accepted';exception when others then if sqlerrm not like '%저장 용량을 초과%' then raise;end if;end;
 update public.properties set trial_ends_at=now()-interval '10 days' where id=prop;
 update omg_private.service_policy set end_action='restrict_writes' where id;
 begin insert into public.calendar_events(property_id,creator_kind,owner_target,title,start_at,end_at,all_day) values(prop,'owner',true,'Blocked test',now(),now()+interval '1 hour',false);raise exception 'Expired write accepted';exception when others then if sqlerrm not like '%이용 기간이 종료%' then raise;end if;end;
 update public.properties set billing_exempt=true where id=prop;
 insert into public.calendar_events(property_id,creator_kind,owner_target,title,start_at,end_at,all_day) values(prop,'owner',true,'Exempt test',now(),now()+interval '1 hour',false);
 perform set_config('request.jwt.claim.sub','',true);
 if public.get_property_service()->>'ok'<>'false' then raise exception 'Unauthenticated service read accepted';end if;
end$$;
select 'PASS policy editing, existing/new trial terms, customer overrides, reminder, quota, expiry enforcement and exemption' as result;

rollback;
