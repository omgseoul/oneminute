-- Cross-property, owner-approved sharing for work status, attendance and missions.
begin;

create table if not exists public.property_share_requests (
  id uuid primary key default gen_random_uuid(),
  requester_property_id uuid not null references public.properties(id),
  target_property_id uuid not null references public.properties(id),
  requester_owner_id uuid not null references public.owners(id),
  requested_permissions text[] not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default clock_timestamp(),
  approved_at timestamptz,
  approved_by uuid references public.owners(id),
  unique(requester_property_id,target_property_id),
  check(requester_property_id<>target_property_id),
  check(cardinality(requested_permissions) between 1 and 3),
  check(requested_permissions <@ array['work_status','attendance_records','missions']::text[])
);

create index if not exists property_share_target_status_idx
  on public.property_share_requests(target_property_id,status,requested_at desc);
alter table public.property_share_requests enable row level security;
revoke all on table public.property_share_requests from public,anon,authenticated;

alter table public.property_messages
  add column if not exists property_share_request_id uuid references public.property_share_requests(id);
alter table public.property_messages drop constraint if exists property_messages_message_type_check;
alter table public.property_messages add constraint property_messages_message_type_check
  check(message_type in ('general','emergency_report','attendance_approval','property_share_approval'));

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
  where x=any(array['work_status','attendance_records','missions']);
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
    array_to_string(array(select case x when 'work_status' then '근무상태' when 'attendance_records' then '근무기록' else '미션' end from unnest(v_permissions)x),', '));
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,priority,message_type,property_share_request_id)
  values(v_target.business_id,v_target.id,'owner',v_session.owner_id,v_message,'normal','property_share_approval',v_request_id)
  returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.property_id=v_target.id and o.active;
  return jsonb_build_object('ok',true,'request_id',v_request_id,'message_id',v_message_id,'status','pending');
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
  update public.property_share_requests set status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.property_share_request_id=v_request.id and r.owner_id=v_owner_id;
  return jsonb_build_object('ok',true,'status','approved');
end;
$$;

create or replace function public.list_property_shares(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 지점을 선택할 수 있습니다.'); end if;
  select coalesce(jsonb_agg(x order by (x->>'is_own')::boolean desc,x->>'property_name'),'[]'::jsonb) into v_items from(
    select jsonb_build_object('property_id',p.id,'property_name',p.name,'management_number',p.management_number,
      'permissions',array['work_status','attendance_records','missions'],'is_own',true) x from public.properties p where p.id=v_property_id
    union all
    select jsonb_build_object('property_id',p.id,'property_name',p.name,'management_number',p.management_number,
      'permissions',r.requested_permissions,'is_own',false) x from public.property_share_requests r
    join public.properties p on p.id=r.target_property_id where r.requester_property_id=v_property_id and r.status='approved'
  )q;
  return jsonb_build_object('ok',true,'properties',v_items);
end;
$$;

create or replace function public.list_working_employees(p_access_token uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_ids uuid[];v_items jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무상태를 볼 수 있습니다.'); end if;
  v_ids:=coalesce(p_property_ids,array[v_property_id]);
  if not(v_property_id=any(v_ids)) or exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'work_status'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','근무상태 공유 권한이 없는 지점이 포함되어 있습니다.');
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
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유 근무기록을 볼 수 있습니다.'); end if;
  if p_from_date is null or p_to_date is null or p_from_date>p_to_date or p_to_date-p_from_date>366 then
    return jsonb_build_object('ok',false,'code','invalid_period','message','조회 기간을 확인해주세요.'); end if;
  v_ids:=coalesce(p_property_ids,array[v_property_id]);
  if not(v_property_id=any(v_ids)) or exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'attendance_records'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','근무기록 공유 권한이 없는 지점이 포함되어 있습니다.'); end if;
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

create or replace function public.list_shared_missions(p_access_token uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_ids uuid[];v_items jsonb:='[]'::jsonb;v_employees jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 공유 미션을 볼 수 있습니다.'); end if;
  v_ids:=coalesce(p_property_ids,array[v_property_id]);
  if not(v_property_id=any(v_ids)) or exists(select 1 from unnest(v_ids)x(id) where x.id<>v_property_id and not exists(
    select 1 from public.property_share_requests r where r.requester_property_id=v_property_id and r.target_property_id=x.id
      and r.status='approved' and 'missions'=any(r.requested_permissions))) then
    return jsonb_build_object('ok',false,'code','forbidden','message','미션 공유 권한이 없는 지점이 포함되어 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'property_id',p.id,'property_name',p.name)
    order by p.name,e.created_at,e.id),'[]'::jsonb) into v_employees from public.employees e join public.properties p on p.id=e.property_id
    where e.property_id=any(v_ids) and e.active and e.role<>'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'property_id',p.id,'property_name',p.name,'is_own_property',p.id=v_property_id,
    'title',m.title,'description',m.description,'description_photo',m.description_photo,'timing',m.timing,'priority',m.priority,
    'creator_type',m.creator_type,'creator_name',case when m.creator_type='owner' then '관리자' else coalesce(creator.display_name,'근무자') end,
    'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,'completed_at',null,'completion_note',null,'completion_photo','',
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,
      'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc
      join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb),
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp()) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb) into v_items
  from public.missions m join public.properties p on p.id=m.property_id left join public.employees creator on creator.id=m.creator_employee_id
  where m.property_id=any(v_ids) and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',true);
end;
$$;

-- Extend the message list with Property-share approval metadata and cross-property sent mail.
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
    select jsonb_build_object('recipient_key','owner','recipient_type','owner','display_name','사장님','sort_key','0')x where not v_is_owner
    union all select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'display_name',e.display_name,'sort_key','1'||e.created_at::text)x from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner' and(v_is_owner or e.id<>v_employee_id)
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where (v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)
      or r.id is not null order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then '사장님' when m.sender_type='staff' then coalesce(se.display_name,'직원') else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' and m.message_type='property_share_approval' then coalesce(tp.name,'')||' 관리자' when rr.recipient_type='owner' then '사장님' else re.display_name end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'approval_status',coalesce(ar.status,psr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$$;

revoke all on function public.lookup_property_share_target(uuid,bigint),public.request_property_share(uuid,bigint,text[]),
  public.approve_property_share(uuid,uuid),public.list_property_shares(uuid),public.list_working_employees(uuid,uuid[]),
  public.list_shared_attendance_statistics(uuid,date,date,uuid[]),public.list_shared_missions(uuid,uuid[]) from public;
grant execute on function public.lookup_property_share_target(uuid,bigint),public.request_property_share(uuid,bigint,text[]),
  public.approve_property_share(uuid,uuid),public.list_property_shares(uuid),public.list_working_employees(uuid,uuid[]),
  public.list_shared_attendance_statistics(uuid,date,date,uuid[]),public.list_shared_missions(uuid,uuid[]) to anon,authenticated;

commit;
select 'Property 공유·결재·지점별 조회 준비 완료' as result;
