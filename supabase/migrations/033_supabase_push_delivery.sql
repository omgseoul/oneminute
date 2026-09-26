-- Additive migration. Existing Firebase delivery remains available during cutover.
begin;
create table if not exists public.push_delivery_attempts (
 delivery_key text primary key,
 status text not null check(status in('sending','sent','failed')),
 lease_id uuid not null,
 lease_until timestamptz not null,
 attempts integer not null default 1,
 updated_at timestamptz not null default clock_timestamp()
);
alter table public.push_delivery_attempts enable row level security;
revoke all on public.push_delivery_attempts from public,anon,authenticated;

create or replace function public.claim_push_delivery(p_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_id uuid:=gen_random_uuid();v_row public.push_delivery_attempts%rowtype;
begin
 if length(p_key) not between 1 and 400 then raise exception 'Invalid delivery key';end if;
 insert into public.push_delivery_attempts(delivery_key,status,lease_id,lease_until)
 values(p_key,'sending',v_id,clock_timestamp()+interval '90 seconds')
 on conflict(delivery_key) do update set status='sending',lease_id=v_id,
 lease_until=clock_timestamp()+interval '90 seconds',attempts=push_delivery_attempts.attempts+1,updated_at=clock_timestamp()
 where push_delivery_attempts.status='failed' or
 (push_delivery_attempts.status='sending' and push_delivery_attempts.lease_until<clock_timestamp())
 returning * into v_row;
 if found then return jsonb_build_object('ok',true,'claimed',true,'lease_id',v_id);end if;
 select * into v_row from public.push_delivery_attempts where delivery_key=p_key;
 return jsonb_build_object('ok',true,'claimed',false,'status',v_row.status);
end;$$;
create or replace function public.finish_push_delivery(p_key text,p_lease_id uuid,p_success boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 update public.push_delivery_attempts set status=case when p_success then 'sent' else 'failed' end,
 updated_at=clock_timestamp() where delivery_key=p_key and lease_id=p_lease_id and status='sending';
 return jsonb_build_object('ok',found);
end;$$;

-- Resolve each recipient's own branch rather than the sender's branch.
create or replace function public.get_message_push_dispatch_v2(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_payload jsonb;v_topics jsonb;
begin
 v_payload:=public.get_message_push_dispatch(p_access_token,p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select coalesce(jsonb_agg(distinct topic),'[]'::jsonb) into v_topics from (
  select 'property_'||p.management_number||'_employee_'||e.id as topic
   from public.property_message_recipients r join public.employees e on e.id=r.employee_id
   join public.properties p on p.id=e.property_id
   where r.message_id=p_message_id and e.active
   and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions s
     where s.employee_id=e.id and s.status='working' and s.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id
   from public.property_message_recipients r join public.owners o on o.id=r.owner_id
   join public.properties p on p.id=o.property_id where r.message_id=p_message_id and o.active
 ) targets;
 return v_payload||jsonb_build_object('recipient_topics',v_topics);
end;$$;

revoke all on function public.claim_push_delivery(text),public.finish_push_delivery(text,uuid,boolean),public.get_message_push_dispatch_v2(uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_push_delivery(text),public.finish_push_delivery(text,uuid,boolean),public.get_message_push_dispatch_v2(uuid,uuid) to service_role;
commit;
select 'supabase push delivery installed' as migration_status;
