begin;
-- Replace inbound email relay with outbound-only notifications and scoped chat links.
update public.guest_email_config set enabled=false;
update public.guest_email_outbox set status='cancelled' where status in('pending','sending');
revoke all on function public.resolve_guest_email(uuid,text),public.receive_guest_email(uuid,uuid,text,text,jsonb) from service_role;
create table public.guest_email_links(
 token_hash text primary key,room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,
 message_id uuid not null unique references public.guest_chat_messages(id) on delete cascade,
 expires_at timestamptz not null);
create table public.guest_email_sessions(
 token_hash text primary key,room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,
 expires_at timestamptz not null,created_at timestamptz not null default now());
alter table public.guest_email_links enable row level security;
alter table public.guest_email_sessions enable row level security;
revoke all on public.guest_email_links,public.guest_email_sessions from public,anon,authenticated;

create or replace function omg_private.queue_guest_email() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.guest_chat_rooms%rowtype;v_payload jsonb;v_link text;v_expires timestamptz;
begin
 if new.sender_kind<>'staff' or not exists(select 1 from public.guest_email_config where enabled) then return new;end if;
 select * into r from public.guest_chat_rooms where id=new.room_id;
 if nullif(btrim(r.email),'') is null or r.status<>'open' or r.expires_at<=now() then return new;end if;
 v_link:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
 v_expires:=least(r.expires_at,now()+interval '14 days');
 select jsonb_build_object('to',lower(r.email),'name',prop.name,'body',new.body,'slug',c.slug,
 'link_token',v_link,'link_expires',v_expires,'asset_path',x.object_path,'asset_mime',x.mime) into v_payload
 from public.properties prop join public.guest_support_config c on c.property_id=prop.id
 left join public.guest_support_assets x on x.id=new.asset_id and x.room_id=r.id and x.ready
 where prop.id=r.property_id and c.enabled and c.chat_enabled;
 if v_payload is not null then
 insert into public.guest_email_links(token_hash,room_id,message_id,expires_at)
 values(encode(sha256(convert_to(v_link,'UTF8')),'hex'),r.id,new.id,v_expires);
 insert into public.guest_email_outbox(message_id,room_id,payload) values(new.id,r.id,v_payload);
 end if;
 return new;
end$$;

create function public.open_guest_email(p_link text,p_new_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_link public.guest_email_links%rowtype;r public.guest_chat_rooms%rowtype;v_slug uuid;
begin
 if p_link is null or p_link !~ '^[a-f0-9]{64}$' or p_new_token is null then raise exception '유효하지 않은 답변 링크입니다.';end if;
 if not exists(select 1 from public.guest_email_config where enabled) then raise exception '현재 이메일 링크를 사용할 수 없습니다. 숙소 QR로 접속해주세요.';end if;
 select * into v_link from public.guest_email_links where token_hash=encode(sha256(convert_to(p_link,'UTF8')),'hex') and expires_at>now();
 if not found then raise exception '답변 링크가 만료되었습니다. 숙소 QR로 다시 접속해주세요.';end if;
 select * into r from public.guest_chat_rooms where id=v_link.room_id and status='open' and expires_at>now();
 if not found then raise exception '종료되었거나 이용 시간이 만료된 대화입니다.';end if;
 select slug into v_slug from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled;
 if v_slug is null then raise exception '현재 숙소 채팅이 중지되어 있습니다.';end if;
 perform omg_private.guest_limit('email-link:'||r.id,30,60);
 delete from public.guest_email_sessions where room_id=r.id and expires_at<=now();
 -- A fresh session for this browser; do not rotate/invalidate the original QR token.
 insert into public.guest_email_sessions(token_hash,room_id,expires_at)
 values(omg_private.token_hash(p_new_token),r.id,least(v_link.expires_at,r.expires_at));
 return jsonb_build_object('ok',true,'room_id',r.id,'slug',v_slug,'guest_token',p_new_token,
 'expires',extract(epoch from least(v_link.expires_at,r.expires_at))*1000);
end$$;
revoke all on function public.open_guest_email(text,uuid) from public,anon,authenticated;
grant execute on function public.open_guest_email(text,uuid) to service_role;

-- Keep existing QR tokens valid and permit an email session only for its mapped room.
do $patch$
declare src text;needle text;
begin
 src:=pg_get_functiondef('public.guest_support_rpc(text,jsonb,uuid,uuid,text)'::regprocedure);
 needle:='where token_hash=omg_private.token_hash(p_guest_token) and expires_at>now()';
 if position(needle in src)=0 then raise exception 'Unexpected guest authentication function; no changes applied';end if;
 src:=replace(src,needle,$replacement$where (token_hash=omg_private.token_hash(p_guest_token)
 or id in(select es.room_id from public.guest_email_sessions es where es.token_hash=omg_private.token_hash(p_guest_token) and es.expires_at>now())) and expires_at>now()$replacement$);
 execute src;
end $patch$;

create function public.fail_guest_email(p_id uuid,p_lease uuid,p_error text) returns void
language sql security definer set search_path='' as $$
 update public.guest_email_outbox set status='failed',last_error=left(p_error,200),leased_until=null
 where message_id=p_id and lease=p_lease and status='sending';
$$;
revoke all on function public.fail_guest_email(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.fail_guest_email(uuid,uuid,text) to service_role;

create or replace function public.claim_guest_emails() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from public.guest_email_config where enabled) then return '[]'::jsonb;end if;
 -- SMTP has no provider idempotency key. Do not automatically replay uncertain sends.
 update public.guest_email_outbox set status='failed',last_error='smtp_delivery_unknown'
 where status='sending' and leased_until<now();
 update public.guest_email_outbox set status='failed',last_error='retry_window_expired'
 where status='pending' and (created_at<now()-interval '23 hours' or attempts>=10);
 update public.guest_email_outbox o set status='cancelled' where status='pending' and exists(
 select 1 from public.guest_chat_rooms r join public.guest_support_config c on c.property_id=r.property_id
 where r.id=o.room_id and (r.status<>'open' or r.expires_at<=now() or not c.enabled or not c.chat_enabled));
 with selected as (select message_id from public.guest_email_outbox where status='pending' and next_at<=now()
 order by created_at for update skip locked limit 5),
 claimed as (update public.guest_email_outbox o set status='sending',attempts=attempts+1,lease=gen_random_uuid(),leased_until=now()+interval '10 minutes'
 from selected s where o.message_id=s.message_id returning o.*)
 select coalesce(jsonb_agg(jsonb_build_object('id',message_id,'lease',lease,'payload',payload)),'[]') into result from claimed;
 return result;
end$$;
commit;
