-- Payroll stays separate from employee config, which is also returned to workers.
create index if not exists work_sessions_employee_property_date_idx on public.work_sessions(employee_id,property_id,work_date);
create table public.employee_payroll_settings (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  pay_type text not null default 'hourly' check(pay_type in ('hourly','monthly')),
  hourly_rate integer check(hourly_rate between 0 and 1000000000),
  monthly_salary integer check(monthly_salary between 0 and 1000000000),
  cycle_start_day integer not null default 1 check(cycle_start_day between 1 and 28),
  pay_day integer check(pay_day between 1 and 31),
  pay_month_offset integer not null default 1 check(pay_month_offset in (0,1)),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.employee_payroll_settings enable row level security;
revoke all on public.employee_payroll_settings from public,anon,authenticated;
comment on table public.employee_payroll_settings is 'Owner-only payroll settings. No direct client access; RPCs validate owner sessions and both attendance/account permissions.';

create function public.save_employee_payroll(p_access_token uuid,p_employee_id uuid,p_settings jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property uuid; v_row public.employee_payroll_settings%rowtype;
begin
  select e.property_id into v_property from public.employees e where e.id=p_employee_id and e.role<>'owner';
  if v_property is null or not coalesce(omg_private.can_manage_shared_property(p_access_token,v_property,'attendance'),false)
    or not coalesce(omg_private.can_manage_shared_property(p_access_token,v_property,'account_settings'),false) then
    return jsonb_build_object('ok',false,'message','해당 근무자의 급여정보를 수정할 권한이 없습니다.');
  end if;
  if p_settings is null or jsonb_typeof(p_settings)<>'object' then
    return jsonb_build_object('ok',false,'message','급여 설정을 확인해주세요.');
  end if;
  -- Reject decimal strings rather than silently rounding money or calendar days.
  if exists(select 1 from jsonb_each_text(p_settings) x where x.key in ('hourly_rate','monthly_salary','cycle_start_day','pay_day','pay_month_offset')
    and x.value is not null and x.value !~ '^[0-9]+$') then
    return jsonb_build_object('ok',false,'message','금액과 날짜는 0 이상의 정수로 입력해주세요.');
  end if;
  v_row.employee_id:=p_employee_id;
  v_row.pay_type:=p_settings->>'pay_type';
  v_row.hourly_rate:=(p_settings->>'hourly_rate')::integer;
  v_row.monthly_salary:=(p_settings->>'monthly_salary')::integer;
  v_row.cycle_start_day:=(p_settings->>'cycle_start_day')::integer;
  v_row.pay_day:=(p_settings->>'pay_day')::integer;
  v_row.pay_month_offset:=(p_settings->>'pay_month_offset')::integer;
  insert into public.employee_payroll_settings(employee_id,pay_type,hourly_rate,monthly_salary,cycle_start_day,pay_day,pay_month_offset)
  values(v_row.employee_id,v_row.pay_type,v_row.hourly_rate,v_row.monthly_salary,v_row.cycle_start_day,v_row.pay_day,v_row.pay_month_offset)
  on conflict(employee_id) do update set pay_type=excluded.pay_type,hourly_rate=excluded.hourly_rate,monthly_salary=excluded.monthly_salary,
    cycle_start_day=excluded.cycle_start_day,pay_day=excluded.pay_day,pay_month_offset=excluded.pay_month_offset,updated_at=clock_timestamp();
  return jsonb_build_object('ok',true);
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation then
  return jsonb_build_object('ok',false,'message','금액(0~10억 원), 시작일(1~28일), 급여일을 확인해주세요.');
end $$;

create function public.list_employee_payroll(p_access_token uuid,p_month date,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_own uuid; v_ids uuid[]; v_month date; v_items jsonb;
begin
  select s.property_id into v_own from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.'); end if;
  if p_month is null or p_month<'2000-01-01'::date or p_month>'2100-12-31'::date then
    return jsonb_build_object('ok',false,'message','조회할 급여월을 확인해주세요.'); end if;
  v_month:=date_trunc('month',p_month)::date;
  v_ids:=case when p_property_ids is null then array[v_own] else p_property_ids end;
  if exists(select 1 from unnest(v_ids) x(id) where not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'attendance'),false)
    or not coalesce(omg_private.can_manage_shared_property(p_access_token,x.id,'account_settings'),false)) then
    return jsonb_build_object('ok',false,'message','급여정보는 근태 및 계정관리 권한이 모두 있는 지점에서 조회할 수 있습니다. 지점 선택을 확인해주세요.');
  end if;
  with settings as (
    select e.id employee_id,e.display_name,e.active,e.created_at,p.id property_id,p.name property_name,p.timezone,
      coalesce(c.pay_type,'hourly') pay_type,c.hourly_rate,c.monthly_salary,coalesce(c.cycle_start_day,1) cycle_start_day,
      c.pay_day,coalesce(c.pay_month_offset,1) pay_month_offset
    from public.employees e join public.properties p on p.id=e.property_id
    left join public.employee_payroll_settings c on c.employee_id=e.id
    where e.property_id=any(v_ids) and e.role<>'owner'
  ), periods as (
    select x.*,v_month+(x.cycle_start_day-1) period_start,
      (v_month+interval '1 month')::date+(x.cycle_start_day-2) period_end from settings x
  ), totals as (
    select x.*,w.work_minutes,w.work_days,w.missing_count,w.working_count,w.session_count,
      (date_trunc('month',x.period_end)+make_interval(months=>x.pay_month_offset))::date pay_month
    from periods x cross join lateral (
      select coalesce(sum(case when s.clock_out_at is not null then greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)) else 0 end),0)::bigint work_minutes,
        count(distinct s.work_date) filter(where s.clock_out_at is not null)::integer work_days,
        count(*) filter(where s.clock_out_at is null and (s.status='needs_review' or s.work_date<(clock_timestamp() at time zone x.timezone)::date))::integer missing_count,
        count(*) filter(where s.clock_out_at is null and s.status<>'needs_review' and s.work_date>=(clock_timestamp() at time zone x.timezone)::date)::integer working_count,
        count(*) session_count
      from public.work_sessions s where s.employee_id=x.employee_id and s.property_id=x.property_id and s.work_date between x.period_start and x.period_end
    ) w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',x.employee_id,'display_name',x.display_name,'active',x.active,'property_id',x.property_id,'property_name',x.property_name,
    'pay_type',x.pay_type,'hourly_rate',x.hourly_rate,'monthly_salary',x.monthly_salary,'cycle_start_day',x.cycle_start_day,
    'pay_day',x.pay_day,'pay_month_offset',x.pay_month_offset,'period_start',x.period_start,'period_end',x.period_end,
    'pay_date',case when x.pay_day is null then null else x.pay_month+least(x.pay_day,extract(day from x.pay_month+interval '1 month - 1 day')::integer)-1 end,
    'work_minutes',x.work_minutes,'work_days',x.work_days,'missing_count',x.missing_count,'working_count',x.working_count,
    'expected_pay',case when x.pay_type='monthly' then x.monthly_salary::numeric else round(x.hourly_rate::numeric*x.work_minutes/60) end
  ) order by x.property_name,x.created_at,x.employee_id),'[]'::jsonb) into v_items
  from totals x where x.active or x.session_count>0;
  return jsonb_build_object('ok',true,'employees',v_items,'month',v_month);
end $$;

revoke all on function public.save_employee_payroll(uuid,uuid,jsonb),public.list_employee_payroll(uuid,date,uuid[]) from public;
grant execute on function public.save_employee_payroll(uuid,uuid,jsonb),public.list_employee_payroll(uuid,date,uuid[]) to anon,authenticated,service_role;
