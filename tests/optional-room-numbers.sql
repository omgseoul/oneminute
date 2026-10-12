begin;
do $test$
declare own public.owners%rowtype; p public.properties%rowtype; token uuid:=gen_random_uuid(); out jsonb; types jsonb:='[{"name":"더블룸","rooms":[]},{"name":"트윈룸","rooms":["101"]}]'; stored jsonb;
begin
 assert omg_private.room_types_are_valid(types);
 assert omg_private.room_types_are_valid('[{"name":"더블룸","rooms":[]}]');
 assert not omg_private.room_types_are_valid('[{"name":"","rooms":[]}]');
 assert not omg_private.room_types_are_valid('[{"name":"더블룸","rooms":["101"]},{"name":"트윈룸","rooms":["101"]}]');
 select * into own from public.owners where active limit 1;
 if not found then raise exception 'No active owner for rollback test'; end if;
 select * into p from public.properties where id=own.property_id;
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at) values(own.id,own.business_id,own.property_id,omg_private.token_hash(token),clock_timestamp()+interval '5 minutes');
 out:=public.save_property_settings(token,p.name,'["101"]'::jsonb,'{}'::jsonb,types,'lodging',p.custom_report_fields);
 assert (out->>'ok')::boolean,out::text;
 select room_types into stored from public.properties where id=p.id;
 assert stored->0->>'name'='더블룸' and stored->0->'rooms'='[]'::jsonb,stored::text;
 out:=public.save_property_settings(token,p.name,'[]'::jsonb,'{}'::jsonb,'[{"name":"더블룸","rooms":[]}]','lodging',p.custom_report_fields);
 assert (out->>'ok')::boolean,out::text;
 assert (select rooms='[]'::jsonb from public.properties where id=p.id);
 out:=public.shared_save_property_settings(token,p.id,p.name,'[]'::jsonb,'{}'::jsonb,'[{"name":"더블룸","rooms":[]}]','lodging',p.custom_report_fields);
 assert (out->>'ok')::boolean,out::text;
 out:=public.save_property_settings(token,p.name,'[]'::jsonb,'{}'::jsonb,'[{"name":"더블룸","rooms":[]}]');
 assert (out->>'ok')::boolean,out::text;
end;
$test$;
select 'Room type names without numbers persist; mixed/empty numbered rooms and both save paths passed; duplicate numbers remain rejected' as test_result;

rollback;
