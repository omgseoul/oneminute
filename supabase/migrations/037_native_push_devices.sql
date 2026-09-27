-- Bind native installations to validated application sessions. FCM remains transport only.
begin;
create table if not exists public.native_push_devices(
 device_id uuid primary key, fcm_token text not null unique,
 actor_key text not null, topic text not null, session_hash text not null,
 expires_at timestamptz not null, updated_at timestamptz not null default now()
);
alter table public.native_push_devices enable row level security;
revoke all on public.native_push_devices from public,anon,authenticated;
create or replace function public.register_native_push(p_access_token uuid,p_device_id uuid,p_fcm_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;n integer;expiry timestamptz;t text;
begin
 a:=omg_private.guest_actor(p_access_token);
 if a is null then raise exception 'Invalid session';end if;
 if p_device_id is null or length(p_fcm_token) not between 50 and 4096 then raise exception 'Invalid device';end if;
 select management_number into n from public.properties where id=(a->>'property_id')::uuid;
 if n is null then raise exception 'Property unavailable';end if;
 if a->>'kind'='owner' then
 select token_expires_at into expiry from public.owner_sessions where login_token_hash=omg_private.token_hash(p_access_token);
 else select token_expires_at into expiry from public.work_sessions where login_token_hash=omg_private.token_hash(p_access_token);end if;
 t:='property_'||n||'_'||replace(a->>'key',':','_');
 -- Token rotation / reinstall must not leave the same device on two accounts.
 delete from public.native_push_devices where fcm_token=p_fcm_token and device_id<>p_device_id;
 insert into public.native_push_devices(device_id,fcm_token,actor_key,topic,session_hash,expires_at)
 values(p_device_id,p_fcm_token,a->>'key',t,omg_private.token_hash(p_access_token),expiry)
 on conflict(device_id) do update set fcm_token=excluded.fcm_token,actor_key=excluded.actor_key,topic=excluded.topic,
 session_hash=excluded.session_hash,expires_at=excluded.expires_at,updated_at=now();
 return jsonb_build_object('ok',true,'actor_key',a->>'key','topic',t);
end$$;
create or replace function public.unregister_native_push(p_access_token uuid,p_device_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 delete from public.native_push_devices where device_id=p_device_id and session_hash=omg_private.token_hash(p_access_token);
 return jsonb_build_object('ok',true);
end$$;
create or replace function public.resolve_native_push_targets(p_topics text[])
returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('topic',t,'device_id',d.device_id,'token',d.fcm_token)),'[]')
 from unnest(p_topics)t left join public.native_push_devices d on d.topic=t and d.expires_at>now()
 and (exists(select 1 from public.work_sessions s join public.employees e on e.id=s.employee_id where s.login_token_hash=d.session_hash and e.active and s.status in('working','completed') and s.token_expires_at>now())
 or exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id where s.login_token_hash=d.session_hash and o.active and s.token_expires_at>now()));
$$;
create or replace function public.invalidate_native_push(p_device_id uuid,p_fcm_token text)
returns void language sql security definer set search_path='' as $$
 delete from public.native_push_devices where device_id=p_device_id and fcm_token=p_fcm_token;
$$;
revoke all on function public.register_native_push(uuid,uuid,text),public.unregister_native_push(uuid,uuid),public.resolve_native_push_targets(text[]),public.invalidate_native_push(uuid,text) from public,anon,authenticated;
grant execute on function public.register_native_push(uuid,uuid,text),public.unregister_native_push(uuid,uuid) to anon,authenticated;
grant execute on function public.resolve_native_push_targets(text[]),public.invalidate_native_push(uuid,text) to service_role;
commit;
select 'native push devices installed' as migration_status;
