-- The selected basis applies to new clock-in reports; existing records are unchanged.
alter table public.properties add column if not exists clock_in_basis text not null default 'first_login';
alter table public.properties add constraint properties_clock_in_basis_check check (clock_in_basis in ('first_login','report'));
alter table public.work_sessions add column if not exists first_login_at timestamptz;

create or replace function public.property_attendance_clock_in_basis(p_access_token uuid,p_action text,p_basis text default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_property_id uuid; v_basis text;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 만료되었습니다.'); end if;
  if p_action='save' then
    if p_basis is null or p_basis not in ('first_login','report') then
      return jsonb_build_object('ok',false,'message','출근시간 기준을 선택해주세요.');
    end if;
    update public.properties set clock_in_basis=p_basis where id=v_property_id;
  elsif p_action is distinct from 'get' then
    return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');
  end if;
  select p.clock_in_basis into v_basis from public.properties p where p.id=v_property_id;
  return jsonb_build_object('ok',true,'basis',v_basis);
end;
$function$;
revoke all on function public.property_attendance_clock_in_basis(uuid,text,text) from public;
grant execute on function public.property_attendance_clock_in_basis(uuid,text,text) to anon,authenticated;

CREATE OR REPLACE FUNCTION public.list_working_employees(p_access_token uuid, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_property_id uuid;
  v_employee_id uuid;
  v_is_owner boolean:=false;
  v_ids uuid[];
  v_property_name text;
  v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;

  if found then
    v_is_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
  end if;

  select p.name into v_property_name from public.properties p where p.id=v_property_id;

  if coalesce(cardinality(p_property_ids),0)=0 then
    if v_is_owner then
      v_ids:=array[v_property_id];
    else
      select array_agg(x.id order by x.sort_order,x.name) into v_ids
      from(
        select p.id,p.name,0 sort_order from public.properties p where p.id=v_property_id
        union
        select p.id,p.name,1 sort_order
        from public.property_share_requests r join public.properties p on p.id=r.target_property_id
        where r.requester_property_id=v_property_id and r.status='approved'
          and 'attendance'=any(r.requested_permissions)
      )x;
    end if;
  else
    v_ids:=p_property_ids;
  end if;

  if exists(
    select 1 from unnest(v_ids)x(id)
    where x.id<>v_property_id and not exists(
      select 1 from public.property_share_requests r
      where r.requester_property_id=v_property_id and r.target_property_id=x.id
        and r.status='approved' and 'attendance'=any(r.requested_permissions)
    )
  ) then
    return jsonb_build_object('ok',false,'code','forbidden','message','근태 공유 권한이 없는 지점이 포함되어 있습니다.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',e.id,
    'display_name',e.display_name,
    'property_id',p.id,
    'property_name',p.name,
    'clock_in_at',s.clock_in_at,
    'has_clock_in_report',s.checkin_report_at is not null,
    'can_message',case
      when not v_is_owner and e.id=v_employee_id then false
      when p.id=v_property_id then true
      else exists(
        select 1 from public.property_share_requests r
        where r.requester_property_id=v_property_id and r.target_property_id=p.id
          and r.status='approved' and 'messages'=any(r.requested_permissions)
      ) end
    ) order by case when p.id=v_property_id then 0 else 1 end,p.name,e.display_name),'[]'::jsonb)
  into v_items
  from public.work_sessions s
  join public.employees e on e.id=s.employee_id
  join public.properties p on p.id=s.property_id
  where s.property_id=any(v_ids) and s.status='working' and s.clock_out_at is null and e.active;

  return jsonb_build_object(
    'ok',true,
    'own_property_id',v_property_id,
    'own_property_name',v_property_name,
    'include_own',v_property_id=any(v_ids),
    'employees',v_items
  );
end;
$function$

CREATE OR REPLACE FUNCTION public.save_work_report(p_access_token uuid, p_report_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_session public.work_sessions%rowtype;
  v_report public.work_reports%rowtype;
  v_employee_name text;
  v_now timestamptz;
  v_payload jsonb;
  v_existing boolean;
  v_basis text;
  v_effective_clock_in timestamptz;
begin
  if p_report_type is null or p_report_type not in ('clock_in', 'clock_out')
     or p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or octet_length(p_payload::text) > 20971520 then
    return jsonb_build_object('ok', false, 'code', 'invalid_report',
      'message', '보고서 형식을 확인해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s
  join public.employees e on e.id = s.employee_id
  where s.login_token_hash = omg_private.token_hash(p_access_token)
    and s.token_expires_at > clock_timestamp() and e.active
    and s.status in ('working', 'completed') for update of s;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_session',
      'message', '로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  select r.* into v_report from public.work_reports r
    where r.work_session_id = v_session.id and r.report_type = p_report_type;
  v_existing := found;
  if not v_existing then
    if v_session.status <> 'working' or v_session.clock_out_at is not null then
      return jsonb_build_object('ok', false, 'code', 'session_completed',
        'message', '이미 종료된 근무입니다.');
    end if;
    v_now := clock_timestamp();
    select p.clock_in_basis into v_basis from public.properties p where p.id=v_session.property_id;
    v_effective_clock_in := case when p_report_type='clock_in' and v_basis='report' then v_now else v_session.clock_in_at end;
    select e.display_name into v_employee_name from public.employees e
      where e.id = v_session.employee_id;
    v_report.id := gen_random_uuid();
    v_payload := p_payload || jsonb_build_object(
      'worker', v_employee_name, 'shift', '근무',
      'report_type', case when p_report_type = 'clock_in' then '출근보고' else '퇴근보고' end,
      'report_id', v_report.id, 'work_session_id', v_session.id,
      'work_date', v_session.work_date, 'attendance_clock_in_at', v_effective_clock_in,
      'submitted_at', v_now
    );
    insert into public.work_reports
      (id, work_session_id, business_id, property_id, employee_id, report_type, payload, submitted_at)
    values (v_report.id, v_session.id, v_session.business_id, v_session.property_id,
      v_session.employee_id, p_report_type, v_payload, v_now)
    returning * into v_report;
    if p_report_type = 'clock_in' then
      update public.work_sessions set checkin_report_at = v_now,
        first_login_at = coalesce(first_login_at, clock_in_at),
        clock_in_at = v_effective_clock_in where id = v_session.id;
    else
      update public.work_sessions set checkout_report_at = v_now, clock_out_at = v_now,
        status = 'completed' where id = v_session.id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'report_id', v_report.id,
    'already_saved', v_existing, 'make_accepted', v_report.make_accepted_at is not null,
    'payload', v_report.payload);
end;
$function$
