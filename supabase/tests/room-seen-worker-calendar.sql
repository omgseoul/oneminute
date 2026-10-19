-- Disposable actors and messages; the transaction always rolls back.
begin;
set local jit=off;
do $test$
declare
 biz uuid:=gen_random_uuid();prop uuid:=gen_random_uuid();other_prop uuid:=gen_random_uuid();
 sender uuid:=gen_random_uuid();receiver uuid:=gen_random_uuid();colleague uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 token_a uuid:=gen_random_uuid();token_b uuid:=gen_random_uuid();token_other uuid:=gen_random_uuid();
 first_id uuid;anchor uuid;future uuid;notice uuid;approval uuid;other_room uuid;holiday uuid:=gen_random_uuid();
 pending uuid:=gen_random_uuid();done uuid:=gen_random_uuid();any_done uuid:=gen_random_uuid();owner_done uuid:=gen_random_uuid();others uuid:=gen_random_uuid();late uuid:=gen_random_uuid();
 sent jsonb;answer jsonb;denied boolean;mid uuid;
begin
 insert into public.businesses(id,name,code) values(biz,'Room seen rollback fixture','seen-'||biz);
 insert into public.properties(id,business_id,name,code,service_status,billing_exempt)
 values(prop,biz,'Seen fixture','seen-'||prop,'active',true),(other_prop,biz,'Other fixture','seen-'||other_prop,'active',true);
 insert into public.owners(id,business_id,property_id,display_name,login_id,pin_hash)
 values(sender,biz,prop,'Sender','seen-'||sender,'fixture'),(outsider,biz,other_prop,'Other','seen-'||outsider,'fixture');
 insert into public.employees(id,business_id,property_id,display_name) values(receiver,biz,prop,'Receiver'),(colleague,biz,prop,'Colleague');
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
 values(sender,biz,prop,omg_private.token_hash(token_a),now()+interval '1 hour'),(outsider,biz,other_prop,omg_private.token_hash(token_other),now()+interval '1 hour');
 insert into public.work_sessions(employee_id,business_id,property_id,shift,login_token_hash,token_expires_at)
 values(receiver,biz,prop,'general',omg_private.token_hash(token_b),now()+interval '1 hour');
 -- Older incoming history exceeds a page; the newest snapshot is our own sticker.
 for n in 1..62 loop
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,created_at)
  values(biz,prop,'owner',sender,'Older incoming '||n,clock_timestamp()-interval '2 hours'+n*interval '1 second') returning id into mid;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(mid,'employee:'||receiver,'staff',receiver);
  if n=1 then first_id:=mid;end if;
 end loop;
 sent:=public.staff_chat_rpc(token_b,'send',jsonb_build_object('peer','owner:'||sender,'body','[시바:청소 완료]','client_id',gen_random_uuid()));anchor:=(sent->>'message_id')::uuid;
 if anchor is null then raise exception 'Outgoing anchor not created: %',sent;end if;
 insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,created_at)
 values(biz,prop,'owner',sender,'Later arrival',clock_timestamp()+interval '1 second') returning id into future;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(future,'employee:'||receiver,'staff',receiver);
 insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message)
 values(biz,prop,'staff',colleague,'Different room') returning id into other_room;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(other_room,'employee:'||receiver,'staff',receiver);
 insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,message_type)
 values(biz,prop,'owner',sender,'Sign and understand this notice','announcement') returning id into notice;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(notice,'employee:'||receiver,'staff',receiver);
 answer:=public.staff_chat_rpc(token_b,'read_room',jsonb_build_object('peer','owner:'||sender,'through_id',anchor));
 if (answer->>'read_count')::int<>62 then raise exception 'History before outgoing anchor not read: %',answer;end if;
 if exists(select 1 from public.property_message_recipients where message_id=first_id and read_at is null)
 or exists(select 1 from public.property_message_recipients where message_id in(future,other_room,notice) and read_at is not null) then raise exception 'Wrong room/cutoff/category modified';end if;
 answer:=public.staff_chat_rpc(token_b,'read_room',jsonb_build_object('peer','owner:'||sender,'through_id',anchor));
 if (answer->>'read_count')::int<>0 then raise exception 'Cursor is not idempotent';end if;
 denied:=false;begin perform public.staff_chat_rpc(token_other,'read_room',jsonb_build_object('peer','owner:'||sender,'through_id',anchor));exception when others then denied:=true;end;
 if not denied then raise exception 'Outsider cursor accepted';end if;
 denied:=false;begin perform public.staff_chat_rpc(token_b,'read_room',jsonb_build_object('peer','employee:'||colleague,'through_id',anchor));exception when others then denied:=true;end;
 if not denied then raise exception 'Wrong peer anchor accepted';end if;
 denied:=false;begin perform public.staff_chat_rpc(gen_random_uuid(),'read_room',jsonb_build_object('peer','owner:'||sender,'through_id',anchor));exception when others then denied:=true;end;
 if not denied then raise exception 'Invalid session accepted';end if;
 -- A pending approval and signature notice become read without processing either.
 insert into public.holiday_requests(id,property_id,requester_employee_id,target_employee_ids,holiday_date,reason)
 values(holiday,prop,receiver,array[colleague],current_date,'Fixture pending request');
 insert into public.property_messages(business_id,property_id,sender_type,message,message_type,holiday_request_id)
 values(biz,prop,'system','Pending holiday','holiday_approval',holiday) returning id into approval;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(approval,'employee:'||receiver,'staff',receiver);
 answer:=public.mark_notification_bot_seen(token_b,approval,array[other_prop]);
 if (answer->>'read_count')::int<>0 then raise exception 'Property selection ignored';end if;
 answer:=public.mark_notification_bot_seen(token_b,approval,array[prop]);
 if (answer->>'read_count')::int<>2 then raise exception 'BOT notice/approval not read: %',answer;end if;
 if exists(select 1 from public.property_message_recipients where message_id in(notice,approval) and (read_at is null or acknowledged_at is not null or acknowledged_understood)) then raise exception 'Read confused with acknowledgement';end if;
 if (select status from public.holiday_requests where id=holiday)<>'pending' then raise exception 'Read processed approval';end if;
 answer:=public.acknowledge_announcement(token_b,notice,'',false);
 if (answer->>'ok')::boolean then raise exception 'Read bypassed required signature/understanding';end if;
 answer:=public.mark_property_message_read(token_b,notice);
 if not (answer->>'ok')::boolean then raise exception 'Reading signature notice blocked';end if;
 if exists(select 1 from public.property_message_recipients where message_id in(future,other_room) and read_at is not null) then raise exception 'BOT read changed ordinary rooms';end if;
 -- Personal completion in all-mode stays hidden although another worker is pending.
 insert into public.missions(id,business_id,property_id,title,due_at,target_employee_ids,completion_mode,owner_completed_at)
 values(pending,biz,prop,'Pending mine',now()+interval '2 hours',jsonb_build_array(receiver),'all',null),
 (done,biz,prop,'Already done by me',now()+interval '2 hours',jsonb_build_array(receiver,colleague),'all',null),
 (any_done,biz,prop,'Anybody completed',now()+interval '2 hours','[]','any',null),
 (owner_done,biz,prop,'Owner completed',now()+interval '2 hours','[]','all',now()),
 (others,biz,prop,'Other worker',now()+interval '2 hours',jsonb_build_array(colleague),'all',null),
 (late,biz,prop,'My late task',now()-interval '2 days',jsonb_build_array(receiver),'all',null);
 insert into public.mission_completions(mission_id,employee_id) values(done,receiver),(any_done,colleague);
 insert into public.calendar_events(property_id,creator_kind,creator_employee_id,target_employee_ids,title,start_at,end_at,holiday_request_id)
 values(prop,'owner',null,array[receiver],'Mine event',now(),now()+interval '1 hour',null),
 (prop,'owner',null,array[colleague],'Other event',now(),now()+interval '1 hour',null),
 (prop,'staff',receiver,array[colleague],'Holiday requested for colleague',now(),now()+interval '1 hour',holiday);
 answer:=public.calendar_event_action(token_b,'list',jsonb_build_object('range_start',now()-interval '3 days','range_end',now()+interval '3 days'));
 if jsonb_array_length(answer->'tasks')<>2 or not exists(select 1 from jsonb_array_elements(answer->'tasks')t where t->>'id'=pending::text) then raise exception 'Personal calendar tasks wrong: %',answer;end if;
 if jsonb_array_length(answer->'events')<>1 or answer->'events'->0->>'title'<>'Mine event' then raise exception 'Other worker calendar event leaked: %',answer;end if;
 answer:=public.list_overdue_calendar_tasks(token_b,null);
 if jsonb_array_length(answer->'tasks')<>1 or answer->'tasks'->0->>'id'<>late::text then raise exception 'Personal overdue tasks wrong: %',answer;end if;
 update public.missions set due_at=now()-interval '1 day' where id in(done,any_done,owner_done,others);
 answer:=public.list_overdue_calendar_tasks(token_b,null);
 if jsonb_array_length(answer->'tasks')<>1 then raise exception 'Completed/other overdue tasks leaked: %',answer;end if;
 answer:=public.calendar_event_action(token_a,'list',jsonb_build_object('range_start',now()-interval '3 days','range_end',now()+interval '3 days'));
 if jsonb_array_length(answer->'tasks')<>6 or jsonb_array_length(answer->'events')<>3 then raise exception 'Owner aggregate calendar changed: %',answer;end if;
end $test$;
select 'PASS: outgoing room cursor reads 62 prior messages; later/other room isolated; BOT read preserves signature and pending approval; personal calendar completion/event isolation; owner aggregate intact' result;
rollback;
