begin;
do $test$
declare own public.owners%rowtype; eid uuid; ot uuid:=gen_random_uuid(); st uuid:=gen_random_uuid(); tid uuid:=gen_random_uuid(); foreignid uuid:=gen_random_uuid(); otherprop uuid; out jsonb;
begin
 select o.* into own from public.owners o where o.active and exists(select 1 from public.employees e where e.property_id=o.property_id and e.active and e.role<>'owner') limit 1;
 if not found then raise exception 'Need owner and staff for rollback test'; end if;
 select id into eid from public.employees where property_id=own.property_id and active and role<>'owner' limit 1;
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at) values(own.id,own.business_id,own.property_id,omg_private.token_hash(ot),clock_timestamp()+interval '5 minutes');
 insert into public.work_sessions(business_id,property_id,employee_id,shift,login_token_hash,token_expires_at,status,clock_out_at) values(own.business_id,own.property_id,eid,'general',omg_private.token_hash(st),clock_timestamp()+interval '5 minutes','completed',clock_timestamp());
 out:=public.employment_contract_rpc(ot,'template_save',jsonb_build_object('employee_id',eid,'id',tid,'name','Rollback template','content','OMS_PRESET_V1:{"kind":"standard"}'));assert (out->>'ok')::boolean,out::text;
 begin perform public.employment_contract_rpc(st,'template_delete',jsonb_build_object('employee_id',eid,'id',tid));raise exception 'Unexpected staff delete';exception when others then assert sqlerrm like '%접근 권한%';end;
 assert exists(select 1 from public.employment_contract_templates where id=tid);
 select id into otherprop from public.properties where id<>own.property_id limit 1;
 if otherprop is not null then
 insert into public.employment_contract_templates(id,property_id,name,content) values(foreignid,otherprop,'Foreign rollback template','Do not delete');
 begin perform public.employment_contract_rpc(ot,'template_delete',jsonb_build_object('employee_id',eid,'id',foreignid));raise exception 'Unexpected cross-property delete';exception when others then assert sqlerrm like '%삭제 권한%';end;
 assert exists(select 1 from public.employment_contract_templates where id=foreignid);
 end if;
 out:=public.employment_contract_rpc(ot,'template_delete',jsonb_build_object('employee_id',eid,'id',tid));assert (out->>'ok')::boolean,out::text;
 assert not exists(select 1 from public.employment_contract_templates where id=tid);
 assert not exists(select 1 from jsonb_array_elements(public.employment_contract_rpc(ot,'list',jsonb_build_object('employee_id',eid))->'templates') t where t->>'id'=tid::text);
end;$test$;
select 'Owner template deletion and list refresh passed; staff and cross-property deletion blocked' as test_result;

rollback;
