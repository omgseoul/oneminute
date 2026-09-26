begin;
-- Existing messages remain the source of truth, including push IDs and retention.
-- A legacy broadcast appears in each recipient's private conversation, not a new group.
create or replace function omg_private.staff_conversation_items(p_actor text)
returns table(id uuid,peer text,body text,priority text,created_at timestamptz,mine boolean,read_at timestamptz,broadcast boolean)
language sql stable security definer set search_path='' as $$
 select m.id,case when s.key=p_actor then r.recipient_key else s.key end,m.message,m.priority,m.created_at,
 s.key=p_actor,r.read_at,(select count(*)>1 from public.property_message_recipients rr where rr.message_id=m.id)
 from public.property_messages m
 cross join lateral(select case when m.sender_type='owner' then 'owner:'||m.sender_owner_id when m.sender_type='staff' then 'employee:'||m.sender_employee_id end key)s
 join public.property_message_recipients r on r.message_id=m.id
 where m.message_type in('general','emergency_report') and s.key is not null
 and (s.key=p_actor or r.recipient_key=p_actor) and s.key<>r.recipient_key;
$$;
revoke all on function omg_private.staff_conversation_items(text) from public,anon,authenticated;
create table if not exists omg_private.staff_chat_sends(
 actor_key text not null,client_id uuid not null,peer text not null,body text not null,priority text not null,
 message_id uuid references public.property_messages(id) on delete cascade,primary key(actor_key,client_id));
alter table omg_private.staff_chat_sends enable row level security;
revoke all on omg_private.staff_chat_sends from public,anon,authenticated;
create or replace function public.staff_chat_rpc(p_access_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';result jsonb;items jsonb;person jsonb;allowed jsonb;
 client uuid;mid uuid;old omg_private.staff_chat_sends%rowtype;ids uuid[];lasttime timestamptz;lastid uuid;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='rooms' then
 with items as(select * from omg_private.staff_conversation_items(actor)),
 latest as(select distinct on(peer) * from items order by peer,created_at desc,id desc)
 select coalesce(jsonb_agg(jsonb_build_object('peer',l.peer,'name',coalesce(o.display_name,e.display_name,'이전 계정'),
 'profile_image',coalesce(o.profile_image,e.profile_image),'property_name',p.name,'preview',l.body,'priority',l.priority,
 'updated_at',l.created_at,'unread',(select count(*) from items i where i.peer=l.peer and not i.mine and i.read_at is null))
 order by l.created_at desc,l.id desc),'[]') into result from latest l
 left join public.owners o on 'owner:'||o.id=l.peer left join public.employees e on 'employee:'||e.id=l.peer
 left join public.properties p on p.id=coalesce(o.property_id,e.property_id);
 return jsonb_build_object('ok',true,'rooms',result);
 end if;
 if p_action='resolve' then
 select i.peer into peerkey from omg_private.staff_conversation_items(actor)i where i.id=(p_data->>'message_id')::uuid order by i.peer limit 1;
 if peerkey is null then raise exception '대화를 찾을 수 없습니다.';end if;
 return jsonb_build_object('ok',true,'peer',peerkey);
 end if;
 if p_action not in('messages','read','send') then raise exception '잘못된 요청입니다.';end if;
 -- New conversations use the same recipient permissions as the original messenger.
 allowed:=public.list_property_messages(p_access_token)->'recipients';
 select j into person from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey;
 if person is null and not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
 raise exception '이 대화에 접근할 수 없습니다.';end if;
 if p_action='send' then
 if person is null then raise exception '현재 이 계정에 메세지를 보낼 수 없습니다.';end if;
 client:=(p_data->>'client_id')::uuid;if client is null then raise exception '전송 번호가 필요합니다.';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor||client,0));
 select * into old from omg_private.staff_chat_sends where actor_key=actor and client_id=client;
 if found then
 if old.peer<>peerkey or old.body<>btrim(p_data->>'body') or old.priority<>coalesce(p_data->>'priority','normal') then raise exception '전송 번호가 중복되었습니다.';end if;
 return jsonb_build_object('ok',true,'message_id',old.message_id,'duplicate',true);
 end if;
 result:=public.send_shared_property_message(p_access_token,
 case when peerkey like 'employee:%' then array[(person->>'employee_id')::uuid] else '{}'::uuid[] end,
 case when peerkey like 'owner:%' then array[(person->>'owner_id')::uuid] else '{}'::uuid[] end,
 p_data->>'body',coalesce(p_data->>'priority','normal'),'general');
 if not (result->>'ok')::boolean then return result;end if;
 insert into omg_private.staff_chat_sends values(actor,client,peerkey,btrim(p_data->>'body'),coalesce(p_data->>'priority','normal'),(result->>'message_id')::uuid);
 return result;
 elsif p_action='read' then
 -- Only acknowledge IDs actually displayed, never unseen pages or notices.
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'));
 update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
 where r.recipient_key=actor and r.message_id=any(ids) and exists(
 select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine and i.id=r.message_id);
 return jsonb_build_object('ok',true);
 end if;
 with page as(select * from omg_private.staff_conversation_items(actor)i where i.peer=peerkey
 and (p_data->>'before_time' is null or (i.created_at,i.id)<((p_data->>'before_time')::timestamptz,(p_data->>'before_id')::uuid))
 and (p_data->>'after_time' is null or (i.created_at,i.id)>((p_data->>'after_time')::timestamptz,(p_data->>'after_id')::uuid))
 order by case when p_data->>'after_time' is not null then i.created_at end asc,
 case when p_data->>'after_time' is not null then i.id end asc,i.created_at desc,i.id desc limit 50)
 select coalesce(jsonb_agg(to_jsonb(page) order by created_at,id),'[]') into items from page;
 if person is null then
 select jsonb_build_object('display_name',coalesce(o.display_name,e.display_name,'이전 계정'),'profile_image',coalesce(o.profile_image,e.profile_image)) into person
 from (select peerkey k)x left join public.owners o on 'owner:'||o.id=x.k left join public.employees e on 'employee:'||e.id=x.k;
 end if;
 return jsonb_build_object('ok',true,'actor',a,'peer',person,'can_send',exists(select 1 from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey),'messages',items);
end$$;
revoke all on function public.staff_chat_rpc(uuid,text,jsonb) from public;
grant execute on function public.staff_chat_rpc(uuid,text,jsonb) to anon,authenticated;
commit;
select 'staff conversations installed' as migration_status;
