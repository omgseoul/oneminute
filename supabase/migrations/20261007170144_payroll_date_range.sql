create function public.list_employee_payroll_range(p_access_token uuid,p_from_date date,p_to_date date,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_own uuid; v_ids uuid[]; v_month date; v_items jsonb;
begin
  select s.property_id into v_own from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.'); end if;
  if p_from_date is null or p_to_date is null or p_from_date<'2000-01-01'::date or p_to_date>'2100-12-31'::date or p_to_date<p_from_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'message','조회기간은 시작일 이후 최대 366일로 선택해주세요.'); end if;
  v_month:=date_trunc('month',p_from_date)::date;
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
    select x.*,p_from_date period_start,p_to_date period_end from settings x
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
    'expected_pay',case when x.pay_type='monthly' then case when extract(day from p_from_date)=x.cycle_start_day and extract(day from p_to_date+1)=x.cycle_start_day then x.monthly_salary::numeric*(12*(extract(year from p_to_date+1)-extract(year from p_from_date))+extract(month from p_to_date+1)-extract(month from p_from_date)) else null end else round(x.hourly_rate::numeric*x.work_minutes/60) end
  ) order by x.property_name,x.created_at,x.employee_id),'[]'::jsonb) into v_items
  from totals x where x.active or x.session_count>0;
  return jsonb_build_object('ok',true,'employees',v_items,'from_date',p_from_date,'to_date',p_to_date);
end $$;


revoke all on function public.list_employee_payroll_range(uuid,date,date,uuid[]) from public;
grant execute on function public.list_employee_payroll_range(uuid,date,date,uuid[]) to anon,authenticated,service_role;
