-- Consolidated share permissions, cross-property messages and delegated attendance approvals.
begin;

alter table public.property_share_requests
  drop constraint if exists property_share_requests_requested_permissions_check;
alter table public.property_share_requests
  drop constraint if exists property_share_requests_requested_permissions_check1;
alter table public.property_share_requests
  drop constraint if exists property_share_requests_permissions_count_check;
alter table public.property_share_requests
  drop constraint if exists property_share_requests_permissions_values_check;

update public.property_share_requests r set requested_permissions=(
  select coalesce(array_agg(x order by x),'{}'::text[])
  from (
    select distinct case when p in ('work_status','attendance_records') then 'attendance' else p end x
    from unnest(r.requested_permissions) p
    where p in ('work_status','attendance_records','missions','messages')
  ) normalized
);

alter table public.property_share_requests add constraint property_share_requests_permissions_count_check
  check(cardinality(requested_permissions) between 1 and 3);
alter table public.property_share_requests add constraint property_share_requests_permissions_values_check
  check(requested_permissions <@ array['attendance','missions','messages']::text[]);

create or replace function public.lookup_property_share_target(p_access_token uuid,p_management_number bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_target public.properties%rowtype;v_request public.property_share_requests%rowtype;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유를 요청할 수 있습니다.'); end if;
  select * into v_target from public.properties p where p.management_number=p_management_number and p.id<>v_property_id;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','해당 Property ID의 지점을 찾을 수 없습니다.'); end if;
  select * into v_request from public.property_share_requests r
  where r.requester_property_id=v_property_id and r.target_property_id=v_target.id;
  return jsonb_build_object('ok',true,'property',jsonb_build_object(
    'property_id',v_target.id,'property_name',v_target.name,'management_number',v_target.management_number),
    'request',case when v_request.id is null then null else jsonb_build_object(
      'request_id',v_request.id,'status',v_request.status,'permissions',v_request.requested_permissions) end);
end;
$$;

create or replace function public.request_property_share(p_access_token uuid,p_target_management_number bigint,p_permissions text[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.owner_sessions%rowtype;v_source public.properties%rowtype;v_target public.properties%rowtype;
  v_permissions text[];v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유를 요청할 수 있습니다.'); end if;
  select array_agg(distinct x order by x) into v_permissions from unnest(coalesce(p_permissions,'{}'::text[])) x
  where x=any(array['attendance','missions','messages']);
  if coalesce(cardinality(v_permissions),0)=0 or cardinality(v_permissions)<>cardinality(p_permissions) then
    return jsonb_build_object('ok',false,'code','permission_required','message','공유받을 항목을 한 개 이상 선택해주세요.');
  end if;
  select * into v_source from public.properties where id=v_session.property_id;
  select * into v_target from public.properties where management_number=p_target_management_number and id<>v_source.id;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','해당 Property ID의 지점을 찾을 수 없습니다.'); end if;
  insert into public.property_share_requests(requester_property_id,target_property_id,requester_owner_id,requested_permissions,status,requested_at,approved_at,approved_by)
  values(v_source.id,v_target.id,v_session.owner_id,v_permissions,'pending',clock_timestamp(),null,null)
  on conflict(requester_property_id,target_property_id) do update set requester_owner_id=excluded.requester_owner_id,
    requested_permissions=excluded.requested_permissions,status='pending',requested_at=clock_timestamp(),approved_at=null,approved_by=null
  returning id into v_request_id;
  v_message:=format(E'Property 공유 요청\n요청 지점: %s (Property ID %s)\n요청 항목: %s',v_source.name,v_source.management_number,
    array_to_string(array(select case x when 'attendance' then '근태' when 'missions' then '미션' else '메세지' end from unnest(v_permissions)x),', '));
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,priority,message_type,property_share_request_id)
  values(v_source.business_id,v_source.id,'owner',v_session.owner_id,v_message,'normal','property_share_approval',v_request_id)
  returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.property_id=v_target.id and o.active;
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending');
end;
$$;

create or replace function public.list_property_shares(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_items jsonb:='[]'::jsonb;v_granted jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 지점을 선택할 수 있습니다.'); end if;
  select coalesce(jsonb_agg(x order by (x->>'is_own')::boolean desc,x->>'property_name'),'[]'::jsonb) into v_items from(
    select jsonb_build_object('property_id',p.id,'property_name',p.name,'management_number',p.management_number,
      'permissions',array['attendance','missions','messages'],'is_own',true) x from public.properties p where p.id=v_property_id
    union all
    select jsonb_build_object('property_id',p.id,'property_name',p.name,'management_number',p.management_number,
      'permissions',r.requested_permissions,'is_own',false,'request_id',r.id) x from public.property_share_requests r
    join public.properties p on p.id=r.target_property_id where r.requester_property_id=v_property_id and r.status='approved'
  )q;
  select coalesce(jsonb_agg(jsonb_build_object('request_id',r.id,'property_id',p.id,'property_name',p.name,
    'management_number',p.management_number,'permissions',r.requested_permissions) order by p.name),'[]'::jsonb) into v_granted
  from public.property_share_requests r join public.properties p on p.id=r.requester_property_id
  where r.target_property_id=v_property_id and r.status='approved';
  return jsonb_build_object('ok',true,'properties',v_items,'granted_properties',v_granted);
end;
$$;

create or replace function public.revoke_property_share(p_access_token uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_property_id uuid;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 권한을 삭제할 수 있습니다.'); end if;
  update public.property_share_requests set status='rejected',approved_at=null,approved_by=null
  where id=p_request_id and target_property_id=v_property_id and status='approved';
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','삭제할 공유 권한을 찾을 수 없습니다.'); end if;
  delete from public.property_message_recipients mr using public.property_messages m,public.attendance_adjustment_requests ar,public.owners o
  where mr.message_id=m.id and m.attendance_request_id=ar.id and ar.status='pending'
    and ar.property_id=v_property_id and mr.owner_id=o.id
    and o.property_id=(select requester_property_id from public.property_share_requests where id=p_request_id);
  return jsonb_build_object('ok',true,'status','revoked');
end;
$$;

create or replace function public.approve_property_share(p_access_token uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_property_id uuid;v_request public.property_share_requests%rowtype;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 결재할 수 있습니다.'); end if;
  select * into v_request from public.property_share_requests where id=p_request_id and target_property_id=v_property_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','공유 요청을 찾을 수 없습니다.'); end if;
  if v_request.status='approved' then return jsonb_build_object('ok',true,'status','approved','already_approved',true); end if;
  if v_request.status<>'pending' then return jsonb_build_object('ok',false,'code','not_pending','message','이미 취소되었거나 만료된 공유 요청입니다.'); end if;
  update public.property_share_requests set status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.property_share_request_id=v_request.id and r.owner_id=v_owner_id;
  if 'messages'=any(v_request.requested_permissions) then
    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
    select m.id,'owner:'||o.id,'owner',o.id
    from public.property_messages m join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id
    join public.owners o on o.property_id=v_request.requester_property_id and o.active
    where ar.property_id=v_request.target_property_id and ar.status='pending'
    on conflict(message_id,recipient_key) do nothing;
  end if;
  return jsonb_build_object('ok',true,'status','approved');
end;
$$;

create or replace function public.list_working_employees(p_access_token uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_ids uuid[];v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무중 현황을 볼 수 있습니다.'); end if;
  v_ids:=case when coalesce(cardinality(p_property_ids),0)=0 then array[v_property_id] else p_property_ids end;
  if exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'attendance'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','근태 공유 권한이 없는 지점이 포함되어 있습니다.');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'property_id',p.id,
    'property_name',p.name,'clock_in_at',s.clock_in_at) order by p.name,e.display_name),'[]'::jsonb) into v_items
  from public.work_sessions s join public.employees e on e.id=s.employee_id join public.properties p on p.id=s.property_id
  where s.property_id=any(v_ids) and s.status='working' and s.clock_out_at is null and e.active;
  return jsonb_build_object('ok',true,'employees',v_items);
end;
$$;

create or replace function public.list_shared_attendance_statistics(p_access_token uuid,p_from_date date,p_to_date date,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  select coalesce(jsonb_agg(jsonb_build_object('session_id',s.id,'property_id',p.id,'property_name',p.name,
    'employee_id',s.employee_id,'employee_name',e.display_name,'work_date',s.work_date,'clock_in_at',s.clock_in_at,
    'clock_out_at',s.clock_out_at,'duration_minutes',case when s.clock_out_at is null then null else greatest(0,floor(extract(epoch from(s.clock_out_at-s.clock_in_at))/60)::integer) end,
    'status',s.status,'checkin_report_at',s.checkin_report_at,'checkout_report_at',s.checkout_report_at,
    'adjustment_request_id',r.id,'adjustment_status',r.status,'requested_clock_in_at',r.requested_clock_in_at,
    'requested_clock_out_at',r.requested_clock_out_at) order by s.work_date desc,s.clock_in_at desc),'[]'::jsonb) into v_sessions
  from public.work_sessions s join public.employees e on e.id=s.employee_id join public.properties p on p.id=s.property_id
  left join public.attendance_adjustment_requests r on r.work_session_id=s.id
  where s.property_id=any(v_ids) and s.work_date between p_from_date and p_to_date;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'property_id',p.id,
    'property_name',p.name,'active',e.active) order by p.name,e.created_at,e.id),'[]'::jsonb) into v_employees
  from public.employees e join public.properties p on p.id=e.property_id where e.property_id=any(v_ids) and e.role<>'owner'
    and(e.active or exists(select 1 from public.work_sessions s where s.employee_id=e.id and s.work_date between p_from_date and p_to_date));
  return jsonb_build_object('ok',true,'scope','shared_properties','timezone',v_timezone,'from_date',p_from_date,'to_date',p_to_date,
    'employees',v_employees,'sessions',v_sessions);
end;
$$;

create or replace function public.send_shared_property_message(
  p_access_token uuid,p_recipient_employee_ids uuid[],p_recipient_owner_ids uuid[],p_message text,
  p_priority text default 'normal',p_message_type text default 'general')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property public.properties%rowtype;
  v_sender_type text;v_message_id uuid;v_text text:=btrim(coalesce(p_message,''));
  v_employee_ids uuid[]:=coalesce(p_recipient_employee_ids,'{}'::uuid[]);v_owner_ids uuid[]:=coalesce(p_recipient_owner_ids,'{}'::uuid[]);
  v_employee_count integer:=0;v_owner_count integer:=0;
begin
  if char_length(v_text) not between 1 and 2000 then return jsonb_build_object('ok',false,'code','invalid_message','message','메세지 내용을 입력해주세요.'); end if;
  if p_priority not in ('normal','urgent') or p_message_type not in ('general','emergency_report') then
    return jsonb_build_object('ok',false,'code','invalid_message_type','message','메세지 종류를 확인해주세요.'); end if;
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_sender_type:='owner';select * into v_property from public.properties where id=v_owner_session.property_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    v_sender_type:='staff';select * into v_property from public.properties where id=v_work_session.property_id;
    v_employee_ids:=array_remove(v_employee_ids,v_work_session.employee_id);
  end if;
  select count(*)::integer into v_employee_count from public.employees e where e.active and e.role<>'owner' and e.id=any(v_employee_ids)
    and(e.property_id=v_property.id or(v_sender_type='owner' and exists(select 1 from public.property_share_requests r
      where r.requester_property_id=v_property.id and r.target_property_id=e.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))));
  if v_employee_count<>coalesce(cardinality(v_employee_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 직원이 포함되어 있습니다.'); end if;
  select count(*)::integer into v_owner_count from public.owners o where o.active and o.id=any(v_owner_ids) and(
    (v_sender_type='staff' and(o.property_id=v_property.id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property.id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))))
    or(v_sender_type='owner' and o.property_id=v_property.id and o.id<>v_owner_session.owner_id));
  if v_owner_count<>coalesce(cardinality(v_owner_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 관리자가 포함되어 있습니다.'); end if;
  if v_employee_count+v_owner_count=0 then return jsonb_build_object('ok',false,'code','recipient_required','message','받는 사람을 한 명 이상 선택해주세요.'); end if;
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,message_type)
  values(v_property.business_id,v_property.id,v_sender_type,case when v_sender_type='owner' then v_owner_session.owner_id end,
    case when v_sender_type='staff' then v_work_session.employee_id end,v_text,p_priority,p_message_type) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
  select v_message_id,'employee:'||e.id,'staff',e.id from public.employees e where e.id=any(v_employee_ids);
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.id=any(v_owner_ids);
  return jsonb_build_object('ok',true,'message_id',v_message_id,'priority',p_priority,'sent_at',clock_timestamp());
end;
$$;

create or replace function public.list_property_messages(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property_id uuid;
  v_owner_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb:='[]'::jsonb;v_recipients jsonb:='[]'::jsonb;v_unread integer:=0;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;v_property_id:=v_owner_session.property_id;v_owner_id:=v_owner_session.owner_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    v_property_id:=v_work_session.property_id;v_employee_id:=v_work_session.employee_id;
  end if;
  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients from(
    select jsonb_build_object('recipient_key','owner:'||o.id,'recipient_type','owner','owner_id',o.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
      'sort_key','1'||p.name||e.created_at::text)x from public.employees e join public.properties p on p.id=e.property_id
    where e.active and e.role<>'owner' and e.id<>coalesce(v_employee_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and(e.property_id=v_property_id or(v_is_owner and exists(select 1 from public.property_share_requests r
        where r.requester_property_id=v_property_id and r.target_property_id=e.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))))
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null
      ) and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'approval_status',coalesce(ar.status,psr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$$;

create or replace function public.mark_property_message_read(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;
begin
  select s.owner_id into v_owner_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id into v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  update public.property_message_recipients set read_at=coalesce(read_at,clock_timestamp()) where message_id=p_message_id
    and((v_owner_id is not null and owner_id=v_owner_id)or(v_employee_id is not null and employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.get_message_push_dispatch(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_message public.property_messages%rowtype;v_topics jsonb:='[]'::jsonb;
begin
  select s.owner_id into v_owner_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id into v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select * into v_message from public.property_messages where id=p_message_id
    and((v_owner_id is not null and sender_owner_id=v_owner_id)or(v_employee_id is not null and sender_employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','전송할 메세지를 찾을 수 없습니다.'); end if;
  select coalesce(jsonb_agg(topic),'[]'::jsonb) into v_topics from(
    select 'property_'||p.management_number||'_employee_'||r.employee_id topic from public.property_message_recipients r
      join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id where r.message_id=v_message.id and r.employee_id is not null
    union all
    select 'property_'||p.management_number||'_owner_'||r.owner_id topic from public.property_message_recipients r
      join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id where r.message_id=v_message.id and r.owner_id is not null
  )q;
  return jsonb_build_object('ok',true,'management_number',(select management_number from public.properties where id=v_message.property_id),
    'message_id',v_message.id,'message',case when v_message.priority='urgent' then v_message.message else '[[OMG_NORMAL_MESSAGE]]'||v_message.message end,
    'priority',v_message.priority,'message_type',v_message.message_type,
    'sender_label',case when v_message.sender_type='owner' then '사장님' else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_topics',v_topics,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb));
end;
$$;

create or replace function public.request_attendance_adjustment(p_access_token uuid,p_work_session_id uuid,p_clock_in_time time,p_clock_out_time time)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_login public.work_sessions%rowtype;v_target public.work_sessions%rowtype;v_employee_name text;v_timezone text;
  v_requested_clock_in_at timestamptz;v_requested_clock_out_at timestamptz;v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_login from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 수정 요청할 수 있습니다.'); end if;
  select s.* into v_target from public.work_sessions s where s.id=p_work_session_id and s.property_id=v_login.property_id and s.employee_id=v_login.employee_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 근무 기록을 찾을 수 없습니다.'); end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_target.property_id;
  if p_clock_in_time is null or p_clock_out_time is null then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  v_requested_clock_in_at:=(v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_requested_clock_out_at:=(v_target.work_date+p_clock_out_time+case when p_clock_out_time<=p_clock_in_time then interval '1 day' else interval '0' end) at time zone v_timezone;
  if v_requested_clock_out_at-v_requested_clock_in_at>interval '24 hours' then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  if exists(select 1 from public.attendance_adjustment_requests r where r.work_session_id=v_target.id) then return jsonb_build_object('ok',false,'code','already_requested','message','이미 제출된 수정 요청이 있습니다.'); end if;
  insert into public.attendance_adjustment_requests(business_id,property_id,employee_id,work_session_id,original_clock_in_at,original_clock_out_at,requested_clock_in_at,requested_clock_out_at)
  values(v_target.business_id,v_target.property_id,v_target.employee_id,v_target.id,v_target.clock_in_at,v_target.clock_out_at,v_requested_clock_in_at,v_requested_clock_out_at) returning id into v_request_id;
  select e.display_name into v_employee_name from public.employees e where e.id=v_target.employee_id;
  v_message:=format(E'출퇴근 시간 수정 요청\n근무일: %s\n기존: %s ~ %s\n요청: %s ~ %s',v_target.work_date,
    to_char(v_target.clock_in_at at time zone v_timezone,'HH24:MI'),coalesce(to_char(v_target.clock_out_at at time zone v_timezone,'HH24:MI'),'-'),
    to_char(v_requested_clock_in_at at time zone v_timezone,'HH24:MI'),to_char(v_requested_clock_out_at at time zone v_timezone,'HH24:MI'));
  insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type,attendance_request_id)
  values(v_target.business_id,v_target.property_id,'staff',v_target.employee_id,v_message,'normal','attendance_approval',v_request_id) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select distinct v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.active and(o.property_id=v_target.property_id or exists(
    select 1 from public.property_share_requests r where r.target_property_id=v_target.property_id and r.requester_property_id=o.property_id
      and r.status='approved' and 'messages'=any(r.requested_permissions)));
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending','employee_name',v_employee_name);
end;
$$;

create or replace function public.approve_attendance_adjustment(p_access_token uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_owner_id uuid;v_request public.attendance_adjustment_requests%rowtype;
begin
  select s.property_id,s.owner_id into v_property_id,v_owner_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 결재할 수 있습니다.'); end if;
  select * into v_request from public.attendance_adjustment_requests where id=p_request_id for update;
  if not found or not(v_request.property_id=v_property_id or exists(select 1 from public.property_share_requests r
    where r.requester_property_id=v_property_id and r.target_property_id=v_request.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','not_found','message','결재 권한이 있는 수정 요청을 찾을 수 없습니다.'); end if;
  if v_request.status='approved' then return jsonb_build_object('ok',true,'status','approved','already_approved',true); end if;
  update public.work_sessions set clock_in_at=v_request.requested_clock_in_at,clock_out_at=v_request.requested_clock_out_at,status='completed' where id=v_request.work_session_id and property_id=v_request.property_id;
  update public.attendance_adjustment_requests set status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp()) from public.property_messages m
    where r.message_id=m.id and m.attendance_request_id=v_request.id and r.recipient_type='owner';
  return jsonb_build_object('ok',true,'status','approved');
end;
$$;

revoke all on function public.revoke_property_share(uuid,uuid),
  public.send_shared_property_message(uuid,uuid[],uuid[],text,text,text) from public;
grant execute on function public.lookup_property_share_target(uuid,bigint),public.request_property_share(uuid,bigint,text[]),public.approve_property_share(uuid,uuid),
  public.list_property_shares(uuid),public.revoke_property_share(uuid,uuid),public.list_working_employees(uuid,uuid[]),
  public.list_shared_attendance_statistics(uuid,date,date,uuid[]),public.send_shared_property_message(uuid,uuid[],uuid[],text,text,text),
  public.list_property_messages(uuid),public.mark_property_message_read(uuid,uuid),public.get_message_push_dispatch(uuid,uuid),
  public.request_attendance_adjustment(uuid,uuid,time,time),public.approve_attendance_adjustment(uuid,uuid) to anon,authenticated;

commit;
select '지점 공유 권한·메세지·결재함 준비 완료' as result;
