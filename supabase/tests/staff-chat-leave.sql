begin;
do $test$
declare
 biz uuid:=gen_random_uuid();prop uuid:=gen_random_uuid();other_prop uuid:=gen_random_uuid();
 sender uuid:=gen_random_uuid();receiver uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 token_a uuid:=gen_random_uuid();token_b uuid:=gen_random_uuid();token_other uuid:=gen_random_uuid();
 first_id uuid;second_id uuid;third_id uuid;sent jsonb;answer jsonb;denied boolean;
begin
 insert into public.businesses(id,name,code) values(biz,'Read receipt rollback fixture','receipt-'||biz);
 insert into public.properties(id,business_id,name,code,service_status,billing_exempt)
 values(prop,biz,'Receipt fixture','receipt-'||prop,'active',true),(other_prop,biz,'Other fixture','receipt-'||other_prop,'active',true);
 insert into public.owners(id,business_id,property_id,display_name,login_id,pin_hash)
 values(sender,biz,prop,'Sender','receipt-'||sender,'fixture'),(outsider,biz,other_prop,'Other','receipt-'||outsider,'fixture');
 insert into public.employees(id,business_id,property_id,display_name) values(receiver,biz,prop,'Receiver');
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
 values(sender,biz,prop,omg_private.token_hash(token_a),now()+interval '1 hour'),(outsider,biz,other_prop,omg_private.token_hash(token_other),now()+interval '1 hour');
 insert into public.work_sessions(employee_id,business_id,property_id,shift,login_token_hash,token_expires_at)
 values(receiver,biz,prop,'general',omg_private.token_hash(token_b),now()+interval '1 hour');
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','[시바:청소 완료]','client_id',gen_random_uuid()));
 if not coalesce((sent->>'ok')::boolean,false) then raise exception 'Sticker send failed: %',sent;end if;
 first_id:=(sent->>'message_id')::uuid;
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','Leave unread','client_id',gen_random_uuid()));second_id:=(sent->>'message_id')::uuid;
 if (public.list_property_messages(token_b)->>'unread_count')::int<>2 then raise exception 'Expected two unread';end if;
 answer:=public.staff_chat_rpc(token_a,'messages',jsonb_build_object('peer','employee:'||receiver,'receipt_ids',jsonb_build_array(first_id,second_id),'after_time',now()+interval '1 hour','after_id',first_id));
 if jsonb_array_length(answer->'messages')<>0 or jsonb_array_length(answer->'receipts')<>2 or answer->'receipts'->0->>'read_at' is not null then raise exception 'Unread/incremental receipt projection failed';end if;
 perform public.staff_chat_rpc(token_a,'read',jsonb_build_object('peer','employee:'||receiver,'ids',jsonb_build_array(first_id)));
 if exists(select 1 from public.property_message_recipients where message_id=first_id and read_at is not null) then raise exception 'Sender can spoof recipient read';end if;
 perform public.staff_chat_rpc(token_b,'read',jsonb_build_object('peer','owner:'||sender,'ids',jsonb_build_array(first_id)));
 if (public.list_property_messages(token_b)->>'unread_count')::int<>1 then raise exception 'Read does not decrement home/native shared count';end if;
 answer:=public.staff_chat_native_messages(token_a,jsonb_build_object('peer','employee:'||receiver,'receipt_ids',jsonb_build_array(first_id,second_id),'after_time',now()+interval '1 hour','after_id',first_id));
 if answer->'receipts'->0->>'read_at' is null or answer->'receipts'->1->>'read_at' is not null then raise exception 'Selective read did not update';end if;
 if answer->'receipts'->0 ? 'body' or answer->'receipts'->0 ? 'photo' then raise exception 'Receipts contain message payload';end if;
 answer:=public.staff_chat_rpc(token_b,'messages',jsonb_build_object('peer','owner:'||sender,'receipt_ids',jsonb_build_array(first_id,second_id)));
 if jsonb_array_length(answer->'receipts')<>0 then raise exception 'Incoming message receipt requested as outgoing';end if;
 denied:=false;begin perform public.staff_chat_rpc(token_other,'messages',jsonb_build_object('peer','employee:'||receiver,'receipt_ids',jsonb_build_array(first_id)));exception when others then denied:=true;end;
 if not denied then raise exception 'Outsider can access receipts';end if;
 denied:=false;begin perform public.staff_chat_rpc(gen_random_uuid(),'messages',jsonb_build_object('peer','employee:'||receiver,'receipt_ids',jsonb_build_array(first_id)));exception when others then denied:=true;end;
 if not denied then raise exception 'Unknown session accepted';end if;
 denied:=false;begin perform public.staff_chat_rpc(token_a,'messages',jsonb_build_object('peer','employee:'||receiver,'receipt_ids',(select jsonb_agg(first_id) from generate_series(1,201))));exception when others then denied:=true;end;
 if not denied then raise exception 'Oversized receipt request accepted';end if;

 answer:=public.staff_chat_rpc(token_b,'read',jsonb_build_object('peer','owner:'||sender,'ids',jsonb_build_array(second_id)));
 if jsonb_array_length(answer->'read_ids')<>1 or (answer->>'unread_count')::int<>0 then raise exception 'Confirmed read IDs/count incorrect';end if;
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','Before leaving','client_id',gen_random_uuid()));
 third_id:=(sent->>'message_id')::uuid;
 perform public.staff_chat_rpc(token_b,'leave',jsonb_build_object('peer','owner:'||sender));
 answer:=public.staff_chat_rpc(token_b,'rooms');
 if jsonb_array_length(answer->'rooms')<>0 or (public.list_property_messages(token_b)->>'unread_count')::int<>0 then raise exception 'Leaving must remove own room and clear its unread';end if;
 answer:=public.staff_chat_rpc(token_a,'messages',jsonb_build_object('peer','employee:'||receiver));
 if jsonb_array_length(answer->'messages')<>4 or not (answer->'messages'->3->>'system')::boolean or answer->'messages'->3->>'body'<>'Receiver님이 채팅방을 나갔습니다.' then raise exception 'Peer history or departure notice missing: %',answer;end if;
 perform public.staff_chat_rpc(token_b,'leave',jsonb_build_object('peer','owner:'||sender));
 if (select count(*) from omg_private.staff_chat_events where actor_key='employee:'||receiver)<>1 then raise exception 'Duplicate departure notice';end if;
 perform public.staff_chat_rpc(token_other,'leave',jsonb_build_object('peer','employee:'||receiver));
 if (select count(*) from omg_private.staff_chat_events where actor_key='owner:'||outsider)<>0 then raise exception 'Outsider left another room';end if;
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','New conversation','client_id',gen_random_uuid()));
 answer:=public.staff_chat_rpc(token_b,'messages',jsonb_build_object('peer','owner:'||sender));
 if jsonb_array_length(answer->'messages')<>1 or answer->'messages'->0->>'body'<>'New conversation' then raise exception 'New message must reopen only new history';end if;
 if (public.list_property_messages(token_b)->>'unread_count')::int<>1 then raise exception 'Reopened message unread';end if;
 if has_table_privilege('anon','omg_private.staff_chat_events','select') or has_function_privilege('anon','omg_private.staff_chat_core(uuid,text,jsonb)','execute') then raise exception 'Private implementation exposed';end if;
end
$test$;
select 'PASS: read count 2 -> 1 -> 0, actor-only leave, preserved peer history, system notice, retry/outsider denial, clean reopen;  stickers as text, selective real reads, incremental/native receipt parity, no payload, sender spoof/outsider/session denial and 200-ID cap' as result;
rollback;
