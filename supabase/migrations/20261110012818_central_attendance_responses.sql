-- Responses belong to the original work session, even when read on a later day.
create table omg_private.attendance_warning_responses (
 work_session_id uuid not null references public.work_sessions(id) on delete cascade,
 response_key text not null,
 event_type text not null check(event_type in ('clock_in','clock_out')),
 agreed boolean not null,
 reason text not null default '',
 created_at timestamptz not null default clock_timestamp(),
 primary key(work_session_id,response_key),
 check((agreed and reason='') or (not agreed and char_length(btrim(reason)) between 3 and 500))
);
alter table omg_private.attendance_warning_responses enable row level security;
revoke all on omg_private.attendance_warning_responses from public,anon,authenticated;

create function omg_private.attendance_warning_remark(p_session_id uuid)
returns text language sql stable set search_path='' as $$
 select coalesce(string_agg(
  case event_type when 'clock_in' then '출근' else '퇴근' end || ': ' ||
  case when agreed then '관리자와 기존협의 완료' else reason end,
  E'\n' order by created_at,response_key),'')
 from omg_private.attendance_warning_responses where work_session_id=p_session_id
$$;
revoke all on function omg_private.attendance_warning_remark(uuid) from public,anon,authenticated;

create function public.respond_attendance_warning(p_access_token uuid,p_message_id uuid,p_agreed boolean,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;target_session uuid;event text;employee_name text;recipient uuid;result jsonb;
begin
 if p_agreed is null or (not p_agreed and char_length(btrim(coalesce(p_reason,''))) not between 3 and 500) then
  return jsonb_build_object('ok',false,'message','협의 여부를 선택하고, 아니오인 경우 사유를 3자 이상 입력해주세요.');end if;
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id
 where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active and w.status in('working','completed');
 if not found then return jsonb_build_object('ok',false,'message','근무자 로그인 후 확인해주세요.');end if;
 select r.id,d.work_session_id,d.event_type into recipient,target_session,event
 from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
 join public.attendance_warning_deliveries d on d.message_id=m.id
 join public.work_sessions w on w.id=d.work_session_id
 where m.id=p_message_id and m.message_type='attendance_warning' and r.employee_id=s.employee_id and w.employee_id=s.employee_id
 for update of r;
 if not found then return jsonb_build_object('ok',false,'message','확인할 근태 경고를 찾을 수 없습니다.');end if;
 insert into omg_private.attendance_warning_responses(work_session_id,response_key,event_type,agreed,reason)
 values(target_session,'message:'||p_message_id,event,p_agreed,case when p_agreed then '' else btrim(p_reason) end)
 on conflict do nothing;
 select display_name into employee_name from public.employees where id=s.employee_id;
 update public.property_message_recipients set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
 acknowledged_name=employee_name,acknowledged_understood=true,read_at=coalesce(read_at,clock_timestamp()) where id=recipient;
 return jsonb_build_object('ok',true,'employee_name',employee_name);
end $$;
revoke all on function public.respond_attendance_warning(uuid,uuid,boolean,text) from public;
grant execute on function public.respond_attendance_warning(uuid,uuid,boolean,text) to anon,authenticated;

CREATE OR REPLACE FUNCTION public.respond_checkout_warning(p_access_token uuid, p_rule_id uuid, p_rule_updated_at timestamp with time zone, p_agreed boolean, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.work_sessions%rowtype;pending jsonb;
begin
 if p_agreed is null or (not p_agreed and char_length(btrim(coalesce(p_reason,''))) not between 3 and 500) then
  return jsonb_build_object('ok',false,'message','협의 여부를 선택하고, 아니오인 경우 사유를 3자 이상 입력해주세요.');end if;
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active and w.status='working' for update of w;
 if not found then return jsonb_build_object('ok',false,'message','로그인과 근무 상태를 확인해주세요.');end if;
 pending:=omg_private.pending_checkout_warnings(s.id,clock_timestamp());
 if not exists(select 1 from jsonb_array_elements(pending) x where (x->>'rule_id')::uuid=p_rule_id and (x->>'rule_updated_at')::timestamptz=p_rule_updated_at) then
  return jsonb_build_object('ok',false,'message','경고 조건이 변경되었습니다. 퇴근보고를 다시 눌러주세요.');
 end if;
 insert into omg_private.checkout_warning_confirmations(work_session_id,rule_id,rule_updated_at) values(s.id,p_rule_id,p_rule_updated_at)
 on conflict(work_session_id,rule_id) do update set rule_updated_at=excluded.rule_updated_at,confirmed_at=clock_timestamp();
 insert into omg_private.attendance_warning_responses(work_session_id,response_key,event_type,agreed,reason)
 values(s.id,'checkout:'||p_rule_id,'clock_out',p_agreed,case when p_agreed then '' else btrim(p_reason) end)
 on conflict(work_session_id,response_key) do update set agreed=excluded.agreed,reason=excluded.reason,created_at=clock_timestamp();
 return jsonb_build_object('ok',true);
end $function$

;
revoke all on function public.respond_checkout_warning(uuid,uuid,timestamptz,boolean,text) from public;
grant execute on function public.respond_checkout_warning(uuid,uuid,timestamptz,boolean,text) to anon,authenticated;
-- Older cached pages must refresh instead of bypassing the required response.
CREATE OR REPLACE FUNCTION public.confirm_checkout_warning(p_access_token uuid,p_rule_id uuid,p_rule_updated_at timestamptz)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 select jsonb_build_object('ok',false,'message','화면을 새로고침한 뒤 협의 여부와 사유를 입력해주세요.')
$$;

CREATE OR REPLACE FUNCTION public.acknowledge_announcement(p_access_token uuid, p_message_id uuid, p_employee_name text, p_understood boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_session public.work_sessions%rowtype;v_name text;v_recipient_id uuid;v_signature boolean;v_understanding boolean;v_ack_at timestamptz;
begin
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 확인해주세요.'); end if;
  select display_name into v_name from public.employees where id=v_session.employee_id;
  select r.id,m.require_signature,m.require_understanding into v_recipient_id,v_signature,v_understanding
  from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.message_id=p_message_id and r.employee_id=v_session.employee_id and m.message_type in('announcement','attendance_warning') for update of r;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','확인할 메세지를 찾을 수 없습니다.'); end if;
  if exists(select 1 from public.property_messages where id=p_message_id and message_type='attendance_warning') then return jsonb_build_object('ok',false,'message','화면을 새로고침한 뒤 협의 여부와 사유를 입력해주세요.');end if;
  if v_understanding and not coalesce(p_understood,false) then return jsonb_build_object('ok',false,'code','understanding_required','message','이해했음을 체크해주세요.'); end if;
  if v_signature and btrim(coalesce(p_employee_name,''))<>v_name then return jsonb_build_object('ok',false,'code','name_mismatch','message','본인 이름을 정확히 입력해주세요.'); end if;
  update public.property_message_recipients set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_name=case when v_signature then v_name end,acknowledged_understood=v_understanding,read_at=coalesce(read_at,clock_timestamp()) where id=v_recipient_id returning acknowledged_at into v_ack_at;
  return jsonb_build_object('ok',true,'acknowledged_at',v_ack_at,'employee_name',case when v_signature then v_name end,'understood',v_understanding);
end;
$function$

;
CREATE OR REPLACE FUNCTION public.list_attendance_statistics(p_access_token uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_property_id uuid;
  v_employee_id uuid;
  v_timezone text;
  v_is_owner boolean:=false;
  v_sessions jsonb:='[]'::jsonb;
  v_employees jsonb:='[]'::jsonb;
begin
  select s.property_id,p.timezone into v_property_id,v_timezone
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  join public.properties p on p.id=s.property_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id,p.timezone into v_property_id,v_employee_id,v_timezone
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    join public.properties p on p.id=s.property_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
  end if;
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'code','invalid_period','message','조회 기간을 확인해주세요.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id',s.id,'attendance_remark',omg_private.attendance_warning_remark(s.id),'employee_id',s.employee_id,'employee_name',e.display_name,
    'work_date',s.work_date,'clock_in_at',s.clock_in_at,'clock_out_at',s.clock_out_at,
    'duration_minutes',case when s.clock_out_at is null then null else greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)::integer) end,
    'status',s.status,'checkin_report_at',s.checkin_report_at,'checkout_report_at',s.checkout_report_at,
    'adjustment_request_id',r.id,'adjustment_status',r.status,
    'requested_clock_in_at',r.requested_clock_in_at,'requested_clock_out_at',r.requested_clock_out_at
  ) order by s.work_date desc,s.clock_in_at desc),'[]'::jsonb)
  into v_sessions
  from public.work_sessions s join public.employees e on e.id=s.employee_id
  left join lateral (select ar.* from public.attendance_adjustment_requests ar where ar.work_session_id=s.id order by ar.requested_at desc,ar.id desc limit 1) r on true
  where s.property_id=v_property_id and s.work_date between p_from_date and p_to_date
    and(v_is_owner or s.employee_id=v_employee_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'employee_id',e.id,'display_name',e.display_name,'active',e.active
  ) order by e.active desc,e.created_at,e.id),'[]'::jsonb) into v_employees
  from public.employees e where e.property_id=v_property_id and e.role<>'owner'
    and(v_is_owner or e.id=v_employee_id)
    and(e.active or exists(select 1 from public.work_sessions s where s.employee_id=e.id and s.work_date between p_from_date and p_to_date));

  return jsonb_build_object('ok',true,'scope',case when v_is_owner then 'property' else 'self' end,
    'timezone',v_timezone,'from_date',p_from_date,'to_date',p_to_date,
    'employees',v_employees,'sessions',v_sessions);
end;
$function$

;
CREATE OR REPLACE FUNCTION public.list_shared_attendance_statistics(p_access_token uuid, p_from_date date, p_to_date date, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_timezone text;v_ids uuid[];v_sessions jsonb:='[]'::jsonb;v_employees jsonb:='[]'::jsonb;
begin
  select s.property_id,p.timezone into v_property_id,v_timezone from public.owner_sessions s join public.owners o on o.id=s.owner_id
  join public.properties p on p.id=s.property_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유 근태를 볼 수 있습니다.'); end if;
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'code','invalid_period','message','조회 기간을 확인해주세요.'); end if;
  v_ids:=case when coalesce(cardinality(p_property_ids),0)=0 then array[v_property_id] else p_property_ids end;
  if exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'attendance'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','근태 공유 권한이 없는 지점이 포함되어 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('session_id',s.id,'attendance_remark',omg_private.attendance_warning_remark(s.id),'property_id',p.id,'property_name',p.name,
    'employee_id',s.employee_id,'employee_name',e.display_name,'work_date',s.work_date,'clock_in_at',s.clock_in_at,
    'clock_out_at',s.clock_out_at,'duration_minutes',case when s.clock_out_at is null then null else greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)::integer) end,
    'status',s.status,'checkin_report_at',s.checkin_report_at,'checkout_report_at',s.checkout_report_at,
    'adjustment_request_id',r.id,'adjustment_status',r.status,'requested_clock_in_at',r.requested_clock_in_at,
    'requested_clock_out_at',r.requested_clock_out_at) order by s.work_date desc,s.clock_in_at desc),'[]'::jsonb) into v_sessions
  from public.work_sessions s join public.employees e on e.id=s.employee_id join public.properties p on p.id=s.property_id
  left join lateral (select ar.* from public.attendance_adjustment_requests ar where ar.work_session_id=s.id order by ar.requested_at desc,ar.id desc limit 1) r on true
  where s.property_id=any(v_ids) and s.work_date between p_from_date and p_to_date;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'property_id',p.id,
    'property_name',p.name,'active',e.active) order by p.name,e.created_at,e.id),'[]'::jsonb) into v_employees
  from public.employees e join public.properties p on p.id=e.property_id where e.property_id=any(v_ids) and e.role<>'owner'
    and(e.active or exists(select 1 from public.work_sessions s where s.employee_id=e.id and s.work_date between p_from_date and p_to_date));
  return jsonb_build_object('ok',true,'scope','shared_properties','timezone',v_timezone,'from_date',p_from_date,'to_date',p_to_date,
    'employees',v_employees,'sessions',v_sessions);
end;
$function$

;
