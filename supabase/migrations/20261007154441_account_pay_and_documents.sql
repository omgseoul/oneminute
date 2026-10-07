-- Account-only salary access; preserve payroll cycle/payment dates when editing amounts.
create function public.get_employee_account_pay(p_access_token uuid,p_property_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not coalesce(omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings'),false) then
  return jsonb_build_object('ok',false,'message','계정관리 권한이 없습니다.'); end if;
 return jsonb_build_object('ok',true,'employees',(select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'pay_type',p.pay_type,'hourly_rate',p.hourly_rate,'monthly_salary',p.monthly_salary)),'[]'::jsonb) from public.employees e left join public.employee_payroll_settings p on p.employee_id=e.id where e.property_id=p_property_id and e.role<>'owner'));
end $$;
create function public.save_employee_account_pay(p_access_token uuid,p_employee_id uuid,p_hourly integer,p_monthly integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prop uuid;
begin
 select property_id into prop from public.employees where id=p_employee_id and role<>'owner';
 if prop is null or not coalesce(omg_private.can_manage_shared_property(p_access_token,prop,'account_settings'),false) then
 return jsonb_build_object('ok',false,'message','계정관리 권한이 없습니다.'); end if;
 if (p_hourly is not null and p_monthly is not null) or p_hourly<0 or p_monthly<0 or p_hourly>1000000000 or p_monthly>1000000000 then
 return jsonb_build_object('ok',false,'message','시급·월급 중 하나만 0~10억 원으로 입력해주세요.'); end if;
 insert into public.employee_payroll_settings(employee_id,pay_type,hourly_rate,monthly_salary)
 values(p_employee_id,case when p_monthly is not null then 'monthly' else 'hourly' end,p_hourly,p_monthly)
 on conflict(employee_id) do update set pay_type=excluded.pay_type,hourly_rate=excluded.hourly_rate,monthly_salary=excluded.monthly_salary,updated_at=clock_timestamp();
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.get_employee_account_pay(uuid,uuid),public.save_employee_account_pay(uuid,uuid,integer,integer) from public;
grant execute on function public.get_employee_account_pay(uuid,uuid),public.save_employee_account_pay(uuid,uuid,integer,integer) to anon,authenticated,service_role;

create table public.employee_documents (
 id uuid primary key default gen_random_uuid(),
 employee_id uuid not null references public.employees(id) on delete restrict,
 filename text not null check(length(filename) between 1 and 200),
 object_path text not null unique,
 size integer not null check(size between 5 and 10485760),
 created_at timestamptz not null default clock_timestamp()
);
create index employee_documents_employee_created_idx on public.employee_documents(employee_id,created_at desc);
alter table public.employee_documents enable row level security;
revoke all on public.employee_documents from public,anon,authenticated;
grant all on public.employee_documents to service_role;
-- Only the Edge Function's service role may use this authorization RPC. Custom
-- OMS owner sessions (not Supabase Auth JWTs) are validated by the existing helper.
create function public.authorize_employee_documents(p_access_token uuid,p_employee_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare prop uuid;
begin
 select property_id into prop from public.employees where id=p_employee_id and role<>'owner';
 if prop is null or not coalesce(omg_private.can_manage_shared_property(p_access_token,prop,'account_settings'),false) then return null; end if;
 return prop;
end $$;
revoke all on function public.authorize_employee_documents(uuid,uuid) from public,anon,authenticated;
grant execute on function public.authorize_employee_documents(uuid,uuid) to service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('employee-documents','employee-documents',false,10485760,array['application/pdf'])
on conflict(id) do nothing;
