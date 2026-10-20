begin;
-- Short-lived, random receive-only channel capabilities. Never expose a login token
-- or message contents in a channel name/payload. Every signal read uses existing RPC auth.
create table omg_private.chat_live_tickets(
 topic text primary key, actor_key text not null, session_hash text not null,
 expires_at timestamptz not null, created_at timestamptz not null default now()
);
create index chat_live_actor on omg_private.chat_live_tickets(actor_key,expires_at);
alter table omg_private.chat_live_tickets enable row level security;
revoke all on omg_private.chat_live_tickets from public,anon,authenticated;
create function omg_private.chat_session_active(p_hash text,p_actor text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=p_hash and 'owner:'||o.id=p_actor and o.active and s.token_expires_at>now())
 or exists(select 1 from public.work_sessions s join public.employees e on e.id=s.employee_id
 where s.login_token_hash=p_hash and 'employee:'||e.id=p_actor and e.active and s.token_expires_at>now() and s.status in('working','completed'));
$$;
create function public.chat_live_ticket(p_access_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor text;ticket text:='oms-live:'||gen_random_uuid();until timestamptz:=now()+interval '10 minutes';
begin
 actor:=omg_private.guest_actor(p_access_token)->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다.';end if;
 delete from omg_private.chat_live_tickets where expires_at<now();
 -- Rate bound issuance per session, preserving existing tab/device connections.
 if (select count(*) from omg_private.chat_live_tickets where session_hash=omg_private.token_hash(p_access_token) and created_at>now()-interval '1 minute')>=30 then raise exception '잠시 후 다시 연결해주세요.';end if;
 insert into omg_private.chat_live_tickets values(ticket,actor,omg_private.token_hash(p_access_token),until,now());
 return jsonb_build_object('ok',true,'topic',ticket,'expires_at',until);
end $$;
create function public.chat_live_allowed(p_topic text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from omg_private.chat_live_tickets t where t.topic=p_topic and t.expires_at>now()
 and omg_private.chat_session_active(t.session_hash,t.actor_key));
$$;
revoke all on function public.chat_live_ticket(uuid),public.chat_live_allowed(text) from public;
grant execute on function public.chat_live_ticket(uuid),public.chat_live_allowed(text) to anon,authenticated;
create policy oms_live_receive on realtime.messages for select to anon,authenticated
 using (extension='broadcast' and public.chat_live_allowed((select realtime.topic())));
create function omg_private.chat_signal(p_actor text) returns void
language plpgsql security definer set search_path='' as $$
declare t record;
begin
 for t in select topic from omg_private.chat_live_tickets where actor_key=p_actor and expires_at>now()
 and omg_private.chat_session_active(session_hash,actor_key) loop
  perform realtime.send('{}'::jsonb,'changed',t.topic,true);
 end loop;
exception when others then raise warning 'Chat live signal unavailable; clients will reconcile';
end $$;
create function omg_private.chat_recipient_signal() returns trigger
language plpgsql security definer set search_path='' as $$
declare sender text;
begin
 if tg_op='UPDATE' and new.read_at is not distinct from old.read_at then return new;end if;
 perform omg_private.chat_signal(new.recipient_key);
 select case when sender_type='owner' then 'owner:'||sender_owner_id when sender_type='staff' then 'employee:'||sender_employee_id end into sender
 from public.property_messages where id=new.message_id;
 if sender is not null then perform omg_private.chat_signal(sender);end if;
 return new;
end $$;
create trigger oms_chat_recipient_signal after insert or update of read_at on public.property_message_recipients
 for each row execute function omg_private.chat_recipient_signal();
create function omg_private.chat_leave_signal() returns trigger language plpgsql security definer set search_path='' as $$
begin perform omg_private.chat_signal(new.actor_key);perform omg_private.chat_signal(new.peer);return new;end $$;
create trigger oms_chat_leave_signal after insert on omg_private.staff_chat_events for each row execute function omg_private.chat_leave_signal();
-- Transactional notification queue; client lifecycle is no longer responsible for push.
create table omg_private.chat_push_outbox(
 message_id uuid primary key references public.property_messages(id) on delete cascade,
 created_at timestamptz not null default now(), last_attempt_at timestamptz, attempts integer not null default 0,
 sent_at timestamptz
);
alter table omg_private.chat_push_outbox enable row level security;
revoke all on omg_private.chat_push_outbox from public,anon,authenticated;
create index chat_push_pending on omg_private.chat_push_outbox(created_at) where sent_at is null;
create function omg_private.dispatch_chat_push(p_message uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare secret text;j record;
begin
 select decrypted_secret into secret from vault.decrypted_secrets where name='omg_guest_email_worker_secret';
 if secret is null then return;end if;
 for j in select message_id from omg_private.chat_push_outbox where sent_at is null
 and (p_message is null or message_id=p_message) and (last_attempt_at is null or last_attempt_at<now()-interval '2 minutes')
 and created_at>now()-interval '24 hours' order by created_at limit 30 for update skip locked loop
  perform net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/staff-outbox',
   headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',secret),body:=jsonb_build_object('message_id',j.message_id),timeout_milliseconds:=10000);
  update omg_private.chat_push_outbox set last_attempt_at=now(),attempts=attempts+1 where message_id=j.message_id;
 end loop;
 delete from omg_private.chat_live_tickets where expires_at<now();
end $$;
create function omg_private.enqueue_chat_push() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into omg_private.chat_push_outbox(message_id) values(new.message_id) on conflict do nothing;
 perform omg_private.dispatch_chat_push(new.message_id);return new;end $$;
create trigger oms_chat_enqueue_push after insert on omg_private.staff_chat_sends for each row execute function omg_private.enqueue_chat_push();
create function public.finish_chat_push(p_message_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
begin update omg_private.chat_push_outbox set sent_at=now() where message_id=p_message_id;return jsonb_build_object('ok',true);end $$;
revoke all on function public.finish_chat_push(uuid) from public,anon,authenticated;
grant execute on function public.finish_chat_push(uuid) to service_role;
select cron.schedule('oms-chat-push-outbox','* * * * *','select omg_private.dispatch_chat_push()');
CREATE OR REPLACE FUNCTION omg_private.chat_push_payload(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_message public.property_messages%rowtype;v_number integer;
begin
  select * into v_message from public.property_messages where id=p_message_id and exists(select 1 from omg_private.chat_push_outbox q where q.message_id=p_message_id);
  if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
  select management_number into v_number from public.properties where id=v_message.property_id;
  return jsonb_build_object('ok',true,'management_number',v_number,'message_id',v_message.id,
    'message',case when v_message.priority='urgent' then v_message.message else '[[OMG_NORMAL_MESSAGE]]'||v_message.message end,
    'priority',v_message.priority,'message_type',v_message.message_type,
    'sender_label',case when v_message.sender_type='owner' then coalesce((select display_name from public.owners where id=v_message.sender_owner_id),'관리자')
      when v_message.sender_type='system' then '근태관리' else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb));
end;
$function$

;
CREATE OR REPLACE FUNCTION public.get_chat_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;v_bot_mode text;v_bot_name text;v_is_bot boolean;
begin
 v_payload:=omg_private.chat_push_payload(p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]',coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림')
 into v_is_bot,v_bot_mode,v_bot_name from public.property_messages m left join public.notification_bots b on b.property_id=m.property_id where m.id=p_message_id;
 if not coalesce(v_is_bot,false) then v_bot_mode:=null;end if;

 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and e.active
  and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions ws where ws.employee_id=e.id and ws.status='working' and ws.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then coalesce(active.alert_mode,'urgent') else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
  from recipients r left join public.guest_chat_alert_preferences n on n.actor_key=r.actor_key
  left join lateral(
   select s->>'alert_mode' alert_mode from jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone (select timezone from public.properties where id=n.home_property_id)t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.target_property=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   order by case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end desc limit 1
  )active on true
  where n.actor_key is null or active.alert_mode is not null
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from targets;
 if v_is_bot then v_payload:=v_payload||jsonb_build_object('sender_label',v_bot_name,'is_bot',true,'priority',case when v_bot_mode='urgent' then 'urgent' else 'normal' end);end if;
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$function$

;
revoke all on function public.get_chat_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_chat_push_dispatch(uuid) to service_role;
CREATE OR REPLACE FUNCTION public.staff_chat_rpc(p_access_token uuid, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';answer jsonb;stamp timestamptz;confirmed jsonb;seen_at timestamptz;seen_id uuid;changed_count integer;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='leave' then
  if peerkey is null or peerkey!~'^(owner|employee):[0-9a-f-]{36}$' or peerkey=actor then raise exception '대화를 찾을 수 없습니다.';end if;
  perform pg_advisory_xact_lock(hashtextextended(actor||':'||peerkey,71));
  if not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
   return jsonb_build_object('ok',true,'already_left',true);
  end if;
  stamp:=clock_timestamp();
  update public.property_message_recipients r set read_at=coalesce(r.read_at,stamp)
  where r.recipient_key=actor and exists(select 1 from omg_private.staff_conversation_items(actor)i
    where i.peer=peerkey and not i.mine and i.id=r.message_id and i.created_at<=stamp);
  insert into omg_private.staff_chat_departures values(actor,peerkey,stamp)
  on conflict(actor_key,peer) do update set left_at=excluded.left_at;
  insert into omg_private.staff_chat_events(actor_key,peer,actor_name,created_at) values(actor,peerkey,coalesce(a->>'name','근무자'),stamp);
  return jsonb_build_object('ok',true);
 end if;
 if p_action='read_room' then
  -- The opened room snapshot may end with our own replies/stickers. Its cursor
  -- acknowledges prior incoming history too, without touching later arrivals.
  select i.created_at,i.id into seen_at,seen_id from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and i.id=(p_data->>'through_id')::uuid;
  if seen_id is null then raise exception '확인한 대화 위치를 찾을 수 없습니다.';end if;
  update public.property_message_recipients r set read_at=clock_timestamp()
  where r.recipient_key=actor and r.read_at is null and exists(
   select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine
    and i.id=r.message_id and (i.created_at,i.id)<=(seen_at,seen_id));
  get diagnostics changed_count=row_count;
  return jsonb_build_object('ok',true,'read_count',changed_count,'read_through_id',seen_id,'read_through_at',seen_at,
   'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 end if;
 answer:=omg_private.staff_chat_core(p_access_token,p_action,p_data);
 if p_action='read' then
  select coalesce(jsonb_agg(i.id),'[]'::jsonb) into confirmed from omg_private.staff_conversation_items(actor)i
  where i.peer=peerkey and not i.mine and i.read_at is not null and i.id in(
    select value::uuid from jsonb_array_elements_text(coalesce(p_data->'ids','[]'::jsonb)));
  return answer||jsonb_build_object('read_ids',confirmed,'unread_count',public.list_property_messages(p_access_token)->'unread_count');
 elsif p_action='send' and (answer->>'ok')::boolean then
  return answer||jsonb_build_object('message',(select to_jsonb(i)||jsonb_build_object('client_id',p_data->>'client_id','attachment_type',f.mime_type,'system',false) from omg_private.staff_conversation_items(actor)i left join omg_private.staff_chat_photos f on f.message_id=i.id where i.id=(answer->>'message_id')::uuid and i.peer=peerkey limit 1));
 elsif p_action='messages' then
  return jsonb_set(answer,'{messages}',coalesce((select jsonb_agg(item||jsonb_build_object('client_id',(select s.client_id from omg_private.staff_chat_sends s where s.message_id=(item->>'id')::uuid and s.actor_key=actor),'system',exists(
    select 1 from omg_private.staff_chat_events ev where ev.id=(item->>'id')::uuid)) order by ordinal)
    from jsonb_array_elements(answer->'messages') with ordinality as rows(item,ordinal)),'[]'::jsonb));
 end if;
 return answer;
end $function$

;
revoke all on function omg_private.chat_session_active(text,text),omg_private.chat_signal(text),omg_private.chat_recipient_signal(),omg_private.chat_leave_signal(),omg_private.chat_push_payload(uuid),omg_private.dispatch_chat_push(uuid),omg_private.enqueue_chat_push() from public,anon,authenticated;
set local jit=off;
do $verify$ begin
do $test$
declare
 biz uuid:=gen_random_uuid();prop uuid:=gen_random_uuid();other_prop uuid:=gen_random_uuid();
 sender uuid:=gen_random_uuid();receiver uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();
 token_a uuid:=gen_random_uuid();token_b uuid:=gen_random_uuid();token_other uuid:=gen_random_uuid();
 first_id uuid;second_id uuid;sent jsonb;answer jsonb;denied boolean;ticket jsonb;client uuid:=gen_random_uuid();
begin
 insert into public.businesses(id,name,code) values(biz,'Read receipt rollback fixture','receipt-'||biz);
 insert into public.properties(id,business_id,name,code,service_status,billing_exempt)
 values(prop,biz,'Receipt fixture','receipt-'||prop,'active',true),(other_prop,biz,'Other fixture','receipt-'||other_prop,'active',true);
 update public.properties set management_number=987654321 where id=prop;
 insert into public.owners(id,business_id,property_id,display_name,login_id,pin_hash)
 values(sender,biz,prop,'Sender','receipt-'||sender,'fixture'),(outsider,biz,other_prop,'Other','receipt-'||outsider,'fixture');
 insert into public.employees(id,business_id,property_id,display_name) values(receiver,biz,prop,'Receiver');
 insert into public.owner_sessions(owner_id,business_id,property_id,login_token_hash,token_expires_at)
 values(sender,biz,prop,omg_private.token_hash(token_a),now()+interval '1 hour'),(outsider,biz,other_prop,omg_private.token_hash(token_other),now()+interval '1 hour');
 insert into public.work_sessions(employee_id,business_id,property_id,shift,login_token_hash,token_expires_at)
 values(receiver,biz,prop,'general',omg_private.token_hash(token_b),now()+interval '1 hour');
 ticket:=public.chat_live_ticket(token_a);
 if not public.chat_live_allowed(ticket->>'topic') or public.chat_live_allowed('oms-live:'||gen_random_uuid()) then raise exception 'Ticket isolation failed';end if;
 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','[시바:청소 완료]','client_id',client));
 if not coalesce((sent->>'ok')::boolean,false) then raise exception 'Sticker send failed: %',sent;end if;
 first_id:=(sent->>'message_id')::uuid;
 if sent->'message'->>'client_id'<>client::text or sent->'message'->>'body'<>'[시바:청소 완료]' then raise exception 'Send projection missing';end if;
 if (select count(*) from omg_private.chat_push_outbox where message_id=first_id)<>1 then raise exception 'Outbox missing';end if;
 answer:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','[시바:청소 완료]','client_id',client));
 if answer->>'message_id'<>first_id::text or not (answer->>'duplicate')::boolean then raise exception 'Retry deduplication failed';end if;
 if (select count(*) from omg_private.chat_push_outbox where message_id=first_id)<>1 then raise exception 'Duplicate outbox';end if;
 answer:=public.get_chat_push_dispatch(first_id);
 if not (answer->>'ok')::boolean or jsonb_array_length(answer->'recipient_topics')<>1 then raise exception 'Server dispatch routing failed: %',answer;end if;
 if has_function_privilege('anon','public.get_chat_push_dispatch(uuid)','execute') or has_function_privilege('authenticated','public.finish_chat_push(uuid)','execute') then raise exception 'Service-only dispatch exposed';end if;

 sent:=public.staff_chat_rpc(token_a,'send',jsonb_build_object('peer','employee:'||receiver,'body','Leave unread','client_id',gen_random_uuid()));second_id:=(sent->>'message_id')::uuid;
 answer:=public.staff_chat_rpc(token_a,'messages',jsonb_build_object('peer','employee:'||receiver,'receipt_ids',jsonb_build_array(first_id,second_id),'after_time',now()+interval '1 hour','after_id',first_id));
 if jsonb_array_length(answer->'messages')<>0 or jsonb_array_length(answer->'receipts')<>2 or answer->'receipts'->0->>'read_at' is not null then raise exception 'Unread/incremental receipt projection failed';end if;
 perform public.staff_chat_rpc(token_a,'read',jsonb_build_object('peer','employee:'||receiver,'ids',jsonb_build_array(first_id)));
 if exists(select 1 from public.property_message_recipients where message_id=first_id and read_at is not null) then raise exception 'Sender can spoof recipient read';end if;
 perform public.staff_chat_rpc(token_b,'read',jsonb_build_object('peer','owner:'||sender,'ids',jsonb_build_array(first_id)));
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
 update public.owner_sessions set token_expires_at=now()-interval '1 second' where owner_id=sender;
 if public.chat_live_allowed(ticket->>'topic') then raise exception 'Expired login ticket accepted';end if;
 denied:=false;begin perform public.chat_live_ticket(token_a);exception when others then denied:=true;end;
 if not denied then raise exception 'Expired login created ticket';end if;
raise exception using errcode='ZX001',message='fixture rollback';
end
$test$;

exception when sqlstate 'ZX001' then null;end $verify$;
commit;
