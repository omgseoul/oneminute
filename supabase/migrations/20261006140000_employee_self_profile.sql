create or replace function public.employee_self_profile(
  p_access_token uuid,
  p_action text default 'get',
  p_profile jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_session public.work_sessions%rowtype;
  v_employee public.employees%rowtype;
  v_name text;
  v_job_title text;
  v_contact_phone text;
  v_bank_account text;
  v_clock_in time;
  v_clock_out time;
  v_lateness integer;
begin
  select s.* into v_session
  from public.work_sessions s
  join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp()
    and e.active
    and s.status in ('working','completed');

  if not found then
    return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;

  if p_action='save' then
    if p_profile is null or jsonb_typeof(p_profile)<>'object' then
      return jsonb_build_object('ok',false,'code','invalid_profile','message','내 정보를 확인해주세요.');
    end if;

    v_name:=btrim(coalesce(p_profile->>'display_name',''));
    v_job_title:=btrim(coalesce(p_profile->>'job_title',''));
    v_contact_phone:=btrim(coalesce(p_profile->>'contact_phone',''));
    v_bank_account:=btrim(coalesce(p_profile->>'bank_account',''));
    begin
      v_clock_in:=nullif(p_profile->>'scheduled_clock_in','')::time;
      v_clock_out:=nullif(p_profile->>'scheduled_clock_out','')::time;
      v_lateness:=nullif(p_profile->>'lateness_threshold_minutes','')::integer;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_profile','message','출퇴근 시간과 지각 기준을 확인해주세요.');
    end;

    if char_length(v_name) not between 1 and 50
      or char_length(v_job_title)>60
      or char_length(v_contact_phone)>40
      or char_length(v_bank_account)>120
      or (v_lateness is not null and (v_lateness<0 or v_lateness>720)) then
      return jsonb_build_object('ok',false,'code','invalid_profile','message','입력한 정보를 확인해주세요.');
    end if;

    update public.employees set
      display_name=v_name,
      job_title=v_job_title,
      contact_phone=v_contact_phone,
      bank_account=v_bank_account,
      scheduled_clock_in=v_clock_in,
      scheduled_clock_out=v_clock_out,
      lateness_threshold_minutes=v_lateness
    where id=v_session.employee_id and property_id=v_session.property_id and active and role<>'owner';
  elsif p_action<>'get' then
    return jsonb_build_object('ok',false,'code','invalid_action','message','잘못된 요청입니다.');
  end if;

  select * into v_employee from public.employees where id=v_session.employee_id;
  return jsonb_build_object(
    'ok',true,
    'employee_id',v_employee.id,
    'display_name',v_employee.display_name,
    'job_title',coalesce(v_employee.job_title,''),
    'contact_phone',coalesce(v_employee.contact_phone,''),
    'bank_account',coalesce(v_employee.bank_account,''),
    'scheduled_clock_in',case when v_employee.scheduled_clock_in is null then null else to_char(v_employee.scheduled_clock_in,'HH24:MI') end,
    'scheduled_clock_out',case when v_employee.scheduled_clock_out is null then null else to_char(v_employee.scheduled_clock_out,'HH24:MI') end,
    'lateness_threshold_minutes',v_employee.lateness_threshold_minutes,
    'has_clock_in_report',v_session.checkin_report_at is not null
  );
end;
$function$;

revoke all on function public.employee_self_profile(uuid,text,jsonb) from public,anon;
grant execute on function public.employee_self_profile(uuid,text,jsonb) to authenticated,service_role;
