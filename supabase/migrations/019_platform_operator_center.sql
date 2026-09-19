-- Platform operator center for managing every tenant without exposing credentials.
begin;

create table if not exists public.platform_administrators (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'OMG WORKS 운영자',
  created_at timestamptz not null default clock_timestamp()
);

alter table public.platform_administrators enable row level security;
revoke all on table public.platform_administrators from public,anon,authenticated;

insert into public.platform_administrators(user_id,display_name)
select id,'OMG WORKS 운영자' from auth.users
where lower(email)=lower('oneminute01@naver.com')
on conflict(user_id) do nothing;

alter table public.properties
  add column if not exists service_status text not null default 'trial',
  add column if not exists trial_ends_at timestamptz,
  add column if not exists operator_note text not null default '',
  add column if not exists status_updated_at timestamptz not null default clock_timestamp(),
  add column if not exists status_updated_by uuid references auth.users(id);

do $$ begin
  if not exists(select 1 from pg_catalog.pg_constraint where conname='properties_service_status_check') then
    alter table public.properties add constraint properties_service_status_check
      check(service_status in('trial','active','suspended','cancelled'));
  end if;
end $$;

update public.properties set service_status='active'
where management_number=1 and service_status='trial';
update public.properties set trial_ends_at=created_at+interval '30 days'
where service_status='trial' and trial_ends_at is null;

create table if not exists public.platform_audit_logs (
  id bigint generated always as identity primary key,
  operator_user_id uuid not null references auth.users(id),
  property_id uuid references public.properties(id),
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  check(jsonb_typeof(detail)='object')
);

alter table public.platform_audit_logs enable row level security;
revoke all on table public.platform_audit_logs from public,anon,authenticated;

create or replace function omg_private.is_platform_administrator(p_user_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.platform_administrators a where a.user_id=p_user_id);
$$;

revoke all on function omg_private.is_platform_administrator(uuid) from public,anon,authenticated;

create or replace function public.is_platform_administrator()
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and omg_private.is_platform_administrator(auth.uid());
$$;

create or replace function public.get_platform_dashboard()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_properties jsonb;v_recent jsonb;
begin
  if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then
    return jsonb_build_object('ok',false,'code','platform_admin_required','message','운영자 권한이 필요합니다.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'property_id',p.id,'management_number',p.management_number,'property_name',p.name,
    'email',coalesce(u.email,''),'service_status',p.service_status,'trial_ends_at',p.trial_ends_at,
    'operator_note',p.operator_note,'created_at',p.created_at,'status_updated_at',p.status_updated_at,
    'administrator_count',(select count(*) from public.owners o where o.property_id=p.id and o.active),
    'employee_count',(select count(*) from public.employees e where e.property_id=p.id and e.active and e.role<>'owner'),
    'working_count',(select count(*) from public.work_sessions s where s.property_id=p.id and s.status='working' and s.clock_out_at is null),
    'reports_7d',(select count(*) from public.work_reports r where r.property_id=p.id and r.submitted_at>=clock_timestamp()-interval '7 days'),
    'mission_count',(select count(*) from public.missions m where m.property_id=p.id and m.active),
    'last_activity',(select max(activity_at) from(
      select max(s.created_at) activity_at from public.work_sessions s where s.property_id=p.id
      union all select max(r.submitted_at) from public.work_reports r where r.property_id=p.id
      union all select max(m.created_at) from public.missions m where m.property_id=p.id
      union all select max(x.created_at) from public.urgent_messages x where x.property_id=p.id
    )activity)
  ) order by p.management_number nulls last,p.created_at,p.id),'[]'::jsonb)
  into v_properties
  from public.properties p
  left join public.account_properties ap on ap.property_id=p.id
  left join auth.users u on u.id=ap.user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'action',l.action,'property_name',p.name,'management_number',p.management_number,
    'detail',l.detail,'created_at',l.created_at
  ) order by l.created_at desc),'[]'::jsonb) into v_recent
  from(select * from public.platform_audit_logs order by created_at desc limit 20)l
  left join public.properties p on p.id=l.property_id;

  return jsonb_build_object('ok',true,'properties',v_properties,'recent_actions',v_recent,
    'summary',jsonb_build_object(
      'total',(select count(*) from public.properties),
      'active',(select count(*) from public.properties where service_status='active'),
      'trial',(select count(*) from public.properties where service_status='trial'),
      'suspended',(select count(*) from public.properties where service_status='suspended'),
      'working_now',(select count(*) from public.work_sessions where status='working' and clock_out_at is null)
    ));
end;
$$;

create or replace function public.update_platform_property(
  p_property_id uuid,p_service_status text,p_operator_note text default ''
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_before text;v_note text:=left(btrim(coalesce(p_operator_note,'')),1000);
begin
  if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then
    return jsonb_build_object('ok',false,'code','platform_admin_required','message','운영자 권한이 필요합니다.');
  end if;
  if p_service_status not in('trial','active','suspended','cancelled') then
    return jsonb_build_object('ok',false,'code','invalid_status','message','이용 상태를 확인해주세요.');
  end if;
  select service_status into v_before from public.properties where id=p_property_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','숙소를 찾을 수 없습니다.');end if;
  update public.properties set service_status=p_service_status,operator_note=v_note,
    status_updated_at=clock_timestamp(),status_updated_by=auth.uid() where id=p_property_id;
  if p_service_status in('suspended','cancelled') then
    update public.owner_sessions set token_expires_at=clock_timestamp() where property_id=p_property_id and token_expires_at>clock_timestamp();
    update public.work_sessions set token_expires_at=clock_timestamp() where property_id=p_property_id and token_expires_at>clock_timestamp();
  end if;
  insert into public.platform_audit_logs(operator_user_id,property_id,action,detail)
  values(auth.uid(),p_property_id,'property_status_updated',jsonb_build_object('before',v_before,'after',p_service_status));
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.reset_platform_property_admin_pin(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_crypto_schema text;v_hash text;
begin
  if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then
    return jsonb_build_object('ok',false,'code','platform_admin_required','message','운영자 권한이 필요합니다.');
  end if;
  select id into v_owner_id from public.owners where property_id=p_property_id and active order by created_at,id limit 1 for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','관리자 계정을 찾을 수 없습니다.');end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_hash using '1234';
  update public.owners set pin_hash=v_hash,login_failures=0,login_locked_until=null where id=v_owner_id;
  update public.owner_sessions set token_expires_at=clock_timestamp() where property_id=p_property_id and token_expires_at>clock_timestamp();
  insert into public.platform_audit_logs(operator_user_id,property_id,action,detail)
  values(auth.uid(),p_property_id,'administrator_pin_reset',jsonb_build_object('owner_id',v_owner_id));
  return jsonb_build_object('ok',true,'temporary_pin','1234');
end;
$$;

-- Suspended tenants cannot create new PIN sessions through the account-scoped login.
create or replace function public.start_account_work_session(p_employee_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_code text;v_property_code text;v_status text;
begin
  select b.code,p.code,p.service_status into v_business_code,v_property_code,v_status from public.account_properties a
  join public.businesses b on b.id=a.business_id join public.properties p on p.id=a.property_id where a.user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'code','account_property_required','message','숙소 정보를 찾을 수 없습니다.');end if;
  if v_status in('suspended','cancelled') then return jsonb_build_object('ok',false,'code','service_unavailable','message','현재 이용이 정지된 숙소입니다. 운영자에게 문의해주세요.');end if;
  return public.start_work_session(p_employee_id,p_pin,'general',v_business_code,v_property_code);
end;
$$;

create or replace function public.start_account_admin_session(p_owner_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_code text;v_property_code text;v_status text;
begin
  select b.code,p.code,p.service_status into v_business_code,v_property_code,v_status from public.account_properties a
  join public.businesses b on b.id=a.business_id join public.properties p on p.id=a.property_id where a.user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'code','account_property_required','message','숙소 정보를 찾을 수 없습니다.');end if;
  if v_status in('suspended','cancelled') then return jsonb_build_object('ok',false,'code','service_unavailable','message','현재 이용이 정지된 숙소입니다. 운영자에게 문의해주세요.');end if;
  return public.start_admin_session(p_owner_id,p_pin,v_business_code,v_property_code);
end;
$$;

revoke all on function public.is_platform_administrator(),public.get_platform_dashboard(),
  public.update_platform_property(uuid,text,text),public.reset_platform_property_admin_pin(uuid) from public,anon;
grant execute on function public.is_platform_administrator(),public.get_platform_dashboard(),
  public.update_platform_property(uuid,text,text),public.reset_platform_property_admin_pin(uuid) to authenticated;

commit;
select '플랫폼 운영자 센터 준비 완료' as result;
