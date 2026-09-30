begin;
-- Off until the sending/receiving domain, secrets, webhook and scheduler are verified.
create table public.guest_email_config(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into public.guest_email_config values(true,false);
create table public.guest_email_routes(
 room_id uuid primary key references public.guest_chat_rooms(id) on delete cascade,
 alias uuid not null unique default gen_random_uuid());
create table public.guest_email_outbox(
 message_id uuid primary key references public.guest_chat_messages(id) on delete cascade,
 room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,
 payload jsonb not null,status text not null default 'pending' check(status in('pending','sending','sent','failed','cancelled')),
 attempts integer not null default 0,created_at timestamptz not null default now(),next_at timestamptz not null default now(),
 lease uuid,leased_until timestamptz,provider_id text,last_error text);
create index guest_email_pending on public.guest_email_outbox(next_at) where status in('pending','sending');
create table public.guest_email_receipts(
 provider_id uuid primary key,room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,
 message_id uuid references public.guest_chat_messages(id) on delete set null,event_id uuid,
 created_at timestamptz not null default now());
do $$declare t text;begin
 foreach t in array array['guest_email_config','guest_email_routes','guest_email_outbox','guest_email_receipts'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 end loop;
end$$;
create function omg_private.queue_guest_email() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.guest_chat_rooms%rowtype;a uuid;v_payload jsonb;
begin
 if new.sender_kind<>'staff' or not exists(select 1 from public.guest_email_config where enabled) then return new;end if;
 select * into r from public.guest_chat_rooms where id=new.room_id;
 if r.email is null or r.status<>'open' or r.expires_at<=now() then return new;end if;
 insert into public.guest_email_routes(room_id) values(r.id) on conflict do nothing;
 select alias into a from public.guest_email_routes where room_id=r.id;
 select jsonb_build_object('alias',replace(a::text,'-',''),'to',lower(r.email),'name',prop.name,'body',new.body,'slug',c.slug,
 'asset_path',x.object_path,'asset_mime',x.mime) into v_payload
 from public.properties prop join public.guest_support_config c on c.property_id=prop.id
 left join public.guest_support_assets x on x.id=new.asset_id and x.room_id=r.id and x.ready
 where prop.id=r.property_id and c.enabled and c.chat_enabled;
 if v_payload is not null then insert into public.guest_email_outbox(message_id,room_id,payload) values(new.id,r.id,v_payload) on conflict do nothing;end if;
 return new;
end$$;
create trigger queue_guest_email after insert on public.guest_chat_messages for each row execute function omg_private.queue_guest_email();

create function public.claim_guest_emails() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not exists(select 1 from public.guest_email_config where enabled) then return '[]'::jsonb;end if;
 update public.guest_email_outbox set status='failed',last_error='retry_window_expired'
 where status in('pending','sending') and (created_at<now()-interval '23 hours' or attempts>=10) and coalesce(leased_until,'-infinity')<now();
 update public.guest_email_outbox o set status='cancelled' where status in('pending','sending') and exists(
 select 1 from public.guest_chat_rooms r join public.guest_support_config c on c.property_id=r.property_id
 where r.id=o.room_id and (r.status<>'open' or r.expires_at<=now() or not c.enabled or not c.chat_enabled));
 with selected as (select message_id from public.guest_email_outbox where status in('pending','sending') and next_at<=now()
 and coalesce(leased_until,'-infinity')<now() order by created_at for update skip locked limit 5),
 claimed as (update public.guest_email_outbox o set status='sending',attempts=attempts+1,lease=gen_random_uuid(),leased_until=now()+interval '3 minutes'
 from selected s where o.message_id=s.message_id returning o.*)
 select coalesce(jsonb_agg(jsonb_build_object('id',message_id,'lease',lease,'payload',payload)),'[]') into result from claimed;
 return result;
end$$;
create function public.finish_guest_email(p_id uuid,p_lease uuid,p_provider text default null,p_error text default null)
returns void language sql security definer set search_path='' as $$
 update public.guest_email_outbox set status=case when p_provider is not null then 'sent' else 'pending' end,
 provider_id=p_provider,last_error=left(p_error,200),leased_until=null,
 next_at=now()+make_interval(secs=>least(3600,(30*power(2,attempts))::integer))
 where message_id=p_id and lease=p_lease and status='sending';
$$;
-- Called only after a signed provider event has been verified and full email fetched server-side.
create function public.resolve_guest_email(p_alias uuid,p_sender text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.guest_chat_rooms%rowtype;
begin
 if not exists(select 1 from public.guest_email_config where enabled) then return null;end if;
 select g.* into r from public.guest_email_routes a join public.guest_chat_rooms g on g.id=a.room_id
 join public.guest_support_config c on c.property_id=g.property_id
 where a.alias=p_alias and lower(g.email)=lower(p_sender) and g.status='open' and g.expires_at>now() and c.enabled and c.chat_enabled;
 if not found then return null;end if;
 return jsonb_build_object('room_id',r.id,'property_id',r.property_id);
end$$;
create function public.receive_guest_email(p_provider uuid,p_alias uuid,p_sender text,p_body text,p_assets jsonb default '[]')
returns jsonb language plpgsql security definer set search_path='' as $$
declare route jsonb;r public.guest_chat_rooms%rowtype;receipt public.guest_email_receipts%rowtype;mid uuid;eid uuid;asset jsonb;aid uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_provider::text,1));
 select * into receipt from public.guest_email_receipts where provider_id=p_provider;
 if found then return jsonb_build_object('ok',true,'event_id',receipt.event_id,'duplicate',true);end if;
 route:=public.resolve_guest_email(p_alias,p_sender);
 if route is null then return jsonb_build_object('ok',false,'rejected',true);end if;
 select * into r from public.guest_chat_rooms where id=(route->>'room_id')::uuid for update;
 if length(p_body)>20000 or jsonb_array_length(p_assets)>5 then raise exception 'email_limit';end if;
 perform omg_private.guest_limit('email:'||r.id,30,60);
 if btrim(p_body)<>'' then
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)
 values(r.id,p_provider,'guest:'||r.id,r.guest_name||' · 이메일','guest',p_body) returning id into mid;
 end if;
 for asset in select value from jsonb_array_elements(p_assets) loop
 if coalesce(asset->>'path','') not like r.property_id::text||'/'||r.id::text||'/email/'||p_provider::text||'/%'
 or coalesce(asset->>'mime','') not in('image/jpeg','image/png','image/webp') then raise exception 'invalid_asset';end if;
 insert into public.guest_support_assets(property_id,room_id,uploader_key,object_path,mime,ready)
 values(r.property_id,r.id,'guest:'||r.id,asset->>'path',asset->>'mime',true) returning id into aid;
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body,asset_id)
 values(r.id,gen_random_uuid(),'guest:'||r.id,r.guest_name||' · 이메일','guest','',aid) returning id into mid;
 end loop;
 if mid is null then return jsonb_build_object('ok',false,'rejected',true);end if;
 insert into public.guest_chat_events(room_id,message_id,event_kind) values(r.id,mid,'message') returning id into eid;
 insert into public.guest_email_receipts(provider_id,room_id,message_id,event_id) values(p_provider,r.id,mid,eid);
 update public.guest_chat_rooms set updated_at=now() where id=r.id;
 return jsonb_build_object('ok',true,'event_id',eid);
end$$;
revoke all on function public.claim_guest_emails(),public.finish_guest_email(uuid,uuid,text,text),public.resolve_guest_email(uuid,text),public.receive_guest_email(uuid,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.claim_guest_emails(),public.finish_guest_email(uuid,uuid,text,text),public.resolve_guest_email(uuid,text),public.receive_guest_email(uuid,uuid,text,text,jsonb) to service_role;
commit;
