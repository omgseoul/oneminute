begin;
do $test$
declare
 biz uuid:=gen_random_uuid();prop uuid:=gen_random_uuid();other_prop uuid:=gen_random_uuid();
 owner_a uuid:=gen_random_uuid();owner_b uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 token_a uuid:=gen_random_uuid();token_b uuid:=gen_random_uuid();token_other uuid:=gen_random_uuid();
 payload jsonb;sent jsonb;retry jsonb;web jsonb;native jsonb;mid uuid;second_id uuid;denied boolean;
begin
 insert into public.businesses(id,name,code) values(biz,'Native chat rollback test','native-'||biz);
 insert into public.properties(id,business_id,name,code,service_status,billing_exempt)
 values(prop,biz,'Native fixture','native-'||prop,'active',true),(other_prop,biz,'Other fixture','native-'||other_prop,'active',true);
 insert into public.owners(id,business_id,property_id,display_name,login_id,pin_hash)
 values(owner_a,biz,prop,'Sender','native-'||owner_a,'fixture'),(outsider,biz,other_prop,'Other','native-'||outsider,'fixture');
 insert into public.employees(id,business_id,property_id,display_name) values(owner_b,biz,prop,'Receiver');
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
 values(owner_a,biz,prop,omg_private.token_hash(token_a),now()+interval '1 hour'),
 
 (outsider,biz,other_prop,omg_private.token_hash(token_other),now()+interval '1 hour');
 insert into public.work_sessions(employee_id,business_id,property_id,shift,login_token_hash,token_expires_at) values(owner_b,biz,prop,'general',omg_private.token_hash(token_b),now()+interval '1 hour');
 payload:=jsonb_build_object('peer','employee:'||owner_b,'body','MP4 fixture','priority','normal','client_id',gen_random_uuid(),'photo','data:video/mp4;base64,AAAAEGZ0eXBpc29tAAAAAA==');
 sent:=public.staff_chat_rpc(token_a,'send',payload);
 if not coalesce((sent->>'ok')::boolean,false) then raise exception 'Send failed: %',sent;end if;
 mid:=(sent->>'message_id')::uuid;
 retry:=public.staff_chat_rpc(token_a,'send',payload);
 if retry->>'message_id'<>mid::text or not (retry->>'duplicate')::boolean then raise exception 'Retry duplicated';end if;
 web:=public.staff_chat_rpc(token_a,'messages',jsonb_build_object('peer','employee:'||owner_b));
 native:=public.staff_chat_native_messages(token_a,jsonb_build_object('peer','employee:'||owner_b));
 if jsonb_array_length(native->'messages')<>1 or native->'messages'->0 ? 'photo'
 or native->'messages'->0->>'attachment_type'<>'video/mp4' or native->'messages'->0->>'id'<>web->'messages'->0->>'id' then raise exception 'Native/web mismatch';end if;
 if public.staff_chat_rpc(token_b,'attachment',jsonb_build_object('peer','owner:'||owner_a,'message_id',mid))->>'mime_type'<>'video/mp4' then raise exception 'Attachment metadata mismatch';end if;
 denied:=false;
 begin perform public.staff_chat_rpc(token_other,'attachment',jsonb_build_object('peer','owner:'||owner_a,'message_id',mid));exception when others then denied:=true;end;
 if not denied then raise exception 'Outsider attachment exposure';end if;
 denied:=false;
 begin perform public.staff_chat_native_messages(gen_random_uuid(),jsonb_build_object('peer','employee:'||owner_b));exception when others then denied:=true;end;
 if not denied then raise exception 'Unknown session accepted';end if;
 denied:=false;
 begin perform public.staff_chat_rpc(token_a,'send',payload||jsonb_build_object('client_id',gen_random_uuid(),'photo','data:video/mp4;base64,AQIDBAUGBwgJCgsMDQ4PEA=='));exception when others then denied:=true;end;
 if not denied then raise exception 'Bad MP4 accepted';end if;
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||owner_b,'body','Leave unread','priority','normal','client_id',gen_random_uuid()));
 second_id:=(sent->>'message_id')::uuid;
 perform public.staff_chat_rpc(token_b,'read',jsonb_build_object('peer','owner:'||owner_a,'ids',jsonb_build_array(mid)));
 if not exists(select 1 from public.property_message_recipients where message_id=mid and recipient_key='employee:'||owner_b and read_at is not null) then raise exception 'Read did not persist';end if;
 if exists(select 1 from public.property_message_recipients where message_id=second_id and read_at is not null) then raise exception 'Unseen message read';end if;
 if not has_function_privilege('anon','public.staff_chat_native_messages(uuid,jsonb)','EXECUTE') then raise exception 'Native API unavailable';end if;
end
$test$;
select 'PASS: native/web parity, MP4 upload/download, duplicate retry, outsider/session denial, malformed MP4 denial and selective read' as result;
rollback;
