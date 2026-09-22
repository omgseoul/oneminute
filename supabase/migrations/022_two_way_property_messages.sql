-- Two-way property messages with per-recipient read state and urgent push routing.
begin;

create table if not exists public.property_messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  sender_type text not null check (sender_type in ('owner','staff','system')),
  sender_owner_id uuid references public.owners(id),
  sender_employee_id uuid references public.employees(id),
  message text not null check (char_length(btrim(message)) between 1 and 2000),
  priority text not null default 'normal' check (priority in ('normal','urgent')),
  message_type text not null default 'general'
    check (message_type in ('general','emergency_report','attendance_approval')),
  attendance_request_id uuid references public.attendance_adjustment_requests(id),
  created_at timestamptz not null default clock_timestamp(),
  check (
    (sender_type='owner' and sender_owner_id is not null and sender_employee_id is null)
    or (sender_type='staff' and sender_employee_id is not null and sender_owner_id is null)
    or (sender_type='system' and sender_owner_id is null and sender_employee_id is null)
  )
);

create table if not exists public.property_message_recipients (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.property_messages(id) on delete cascade,
  recipient_key text not null,
  recipient_type text not null check (recipient_type in ('owner','staff')),
  owner_id uuid references public.owners(id),
  employee_id uuid references public.employees(id),
  read_at timestamptz,
  unique(message_id,recipient_key),
  check (
    (recipient_type='owner' and owner_id is not null and employee_id is null)
    or (recipient_type='staff' and employee_id is not null and owner_id is null)
  )
);

create index if not exists property_messages_property_created_idx
  on public.property_messages(property_id,created_at desc);
create index if not exists property_message_recipients_owner_idx
  on public.property_message_recipients(owner_id,read_at);
create index if not exists property_message_recipients_employee_idx
  on public.property_message_recipients(employee_id,read_at);

alter table public.property_messages enable row level security;
alter table public.property_message_recipients enable row level security;
revoke all on table public.property_messages,public.property_message_recipients from public,anon,authenticated;

-- Preserve the existing emergency-report and attendance-approval history.
insert into public.property_messages(
  id,business_id,property_id,sender_type,sender_employee_id,message,priority,
  message_type,attendance_request_id,created_at
)
select m.id,m.business_id,m.property_id,'staff',m.employee_id,m.message,
  case when m.message_type='urgent' then 'urgent' else 'normal' end,
  case when m.message_type='attendance_approval' then 'attendance_approval' else 'emergency_report' end,
  m.attendance_request_id,m.created_at
from public.urgent_messages m
on conflict(id) do nothing;

insert into public.property_message_recipients(
  message_id,recipient_key,recipient_type,owner_id,read_at
)
select m.id,'owner:'||o.id,'owner',o.id,m.acknowledged_at
from public.urgent_messages m
join public.owners o on o.property_id=m.property_id and o.active
on conflict(message_id,recipient_key) do nothing;

create or replace function public.send_property_message(
  p_access_token uuid,
  p_recipient_employee_ids uuid[],
  p_include_owner boolean,
  p_message text,
  p_priority text default 'normal',
  p_message_type text default 'general'
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner_session public.owner_sessions%rowtype;
  v_work_session public.work_sessions%rowtype;
  v_property public.properties%rowtype;
  v_sender_type text;
  v_message_id uuid;
  v_text text:=btrim(coalesce(p_message,''));
  v_employee_ids uuid[]:=coalesce(p_recipient_employee_ids,'{}'::uuid[]);
  v_owner_count integer:=0;
  v_employee_count integer:=0;
begin
  if char_length(v_text) not between 1 and 2000 then
    return jsonb_build_object('ok',false,'code','invalid_message','message','메세지 내용을 입력해주세요.');
  end if;
  if p_priority not in ('normal','urgent') then
    return jsonb_build_object('ok',false,'code','invalid_priority','message','메세지 종류를 확인해주세요.');
  end if;
  if p_message_type not in ('general','emergency_report') then
    return jsonb_build_object('ok',false,'code','invalid_message_type','message','메세지 종류를 확인해주세요.');
  end if;

  select s.* into v_owner_session from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    v_sender_type:='owner';
    select * into v_property from public.properties where id=v_owner_session.property_id;
    p_include_owner:=false;
  else
    select s.* into v_work_session from public.work_sessions s
    join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
    v_sender_type:='staff';
    select * into v_property from public.properties where id=v_work_session.property_id;
    v_employee_ids:=array_remove(v_employee_ids,v_work_session.employee_id);
  end if;

  select count(*)::integer into v_employee_count from public.employees e
  where e.property_id=v_property.id and e.active and e.role<>'owner' and e.id=any(v_employee_ids);
  if v_employee_count<>coalesce(array_length(v_employee_ids,1),0) then
    return jsonb_build_object('ok',false,'code','invalid_recipient','message','수신 직원 목록을 다시 확인해주세요.');
  end if;
  if p_include_owner then
    select count(*)::integer into v_owner_count from public.owners o
    where o.property_id=v_property.id and o.active;
  end if;
  if v_employee_count+v_owner_count=0 then
    return jsonb_build_object('ok',false,'code','recipient_required','message','받는 사람을 한 명 이상 선택해주세요.');
  end if;

  insert into public.property_messages(
    business_id,property_id,sender_type,sender_owner_id,sender_employee_id,
    message,priority,message_type
  ) values(
    v_property.business_id,v_property.id,v_sender_type,
    case when v_sender_type='owner' then v_owner_session.owner_id end,
    case when v_sender_type='staff' then v_work_session.employee_id end,
    v_text,p_priority,p_message_type
  ) returning id into v_message_id;

  insert into public.property_message_recipients(
    message_id,recipient_key,recipient_type,employee_id
  ) select v_message_id,'employee:'||e.id,'staff',e.id
    from public.employees e
    where e.property_id=v_property.id and e.active and e.role<>'owner' and e.id=any(v_employee_ids);

  if p_include_owner then
    insert into public.property_message_recipients(
      message_id,recipient_key,recipient_type,owner_id
    ) select v_message_id,'owner:'||o.id,'owner',o.id
      from public.owners o where o.property_id=v_property.id and o.active;
  end if;

  return jsonb_build_object(
    'ok',true,'message_id',v_message_id,'priority',p_priority,
    'management_number',v_property.management_number,'sent_at',clock_timestamp()
  );
end;
$$;

create or replace function public.list_property_messages(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner_session public.owner_sessions%rowtype;
  v_work_session public.work_sessions%rowtype;
  v_property_id uuid;
  v_owner_id uuid;
  v_employee_id uuid;
  v_is_owner boolean:=false;
  v_items jsonb:='[]'::jsonb;
  v_recipients jsonb:='[]'::jsonb;
  v_unread integer:=0;
begin
  select s.* into v_owner_session from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    v_is_owner:=true;v_property_id:=v_owner_session.property_id;v_owner_id:=v_owner_session.owner_id;
  else
    select s.* into v_work_session from public.work_sessions s
    join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
    v_property_id:=v_work_session.property_id;v_employee_id:=v_work_session.employee_id;
  end if;

  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients
  from (
    select jsonb_build_object('recipient_key','owner','recipient_type','owner','display_name','사장님','sort_key','0') x
    where not v_is_owner
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff',
      'employee_id',e.id,'display_name',e.display_name,'sort_key','1'||e.created_at::text) x
    from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner'
      and(v_is_owner or e.id<>v_employee_id)
  )q;

  select count(*)::integer into v_unread
  from public.property_message_recipients r
  join public.property_messages m on m.id=r.message_id
  where m.property_id=v_property_id and r.read_at is null
    and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));

  with visible as (
    select m.*,
      r.read_at as current_read_at,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
           else m.sender_type='staff' and m.sender_employee_id=v_employee_id end as is_sender
    from public.property_messages m
    left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where m.property_id=v_property_id and(
      (v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)
      or r.id is not null
    ) order by m.created_at desc limit 150
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'message_id',m.id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'is_sender',m.is_sender,
    'sender_type',m.sender_type,'sender_label',case when m.sender_type='owner' then '사장님'
      when m.sender_type='staff' then coalesce(se.display_name,'직원') else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then '사장님' else re.display_name end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'approval_status',ar.status,
    'original_clock_in_at',ar.original_clock_in_at,'original_clock_out_at',ar.original_clock_out_at,
    'requested_clock_in_at',ar.requested_clock_in_at,'requested_clock_out_at',ar.requested_clock_out_at,
    'work_date',ws.work_date
  ) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m
  left join public.employees se on se.id=m.sender_employee_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id
  left join public.work_sessions ws on ws.id=ar.work_session_id;

  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'unread_count',v_unread,
    'recipients',v_recipients,'messages',v_items);
end;
$$;

create or replace function public.mark_property_message_read(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s
    join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.id=p_message_id and m.property_id=v_property_id
    and((v_owner_id is not null and r.owner_id=v_owner_id)or(v_employee_id is not null and r.employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.get_message_push_dispatch(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_message public.property_messages%rowtype;v_number integer;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s
    join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select * into v_message from public.property_messages where id=p_message_id and property_id=v_property_id
    and((v_owner_id is not null and sender_owner_id=v_owner_id)or(v_employee_id is not null and sender_employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','전송할 메세지를 찾을 수 없습니다.'); end if;
  if v_message.priority<>'urgent' then return jsonb_build_object('ok',true,'ignored',true); end if;
  select management_number into v_number from public.properties where id=v_property_id;
  return jsonb_build_object('ok',true,'management_number',v_number,'message_id',v_message.id,
    'message',v_message.message,'sender_label',case when v_message.sender_type='owner' then '사장님'
      else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb));
end;
$$;

create or replace function public.send_urgent_message(p_access_token uuid,p_message text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  return public.send_property_message(p_access_token,'{}'::uuid[],true,p_message,'urgent','emergency_report');
end;
$$;

-- Replace attendance request creation so line breaks render correctly and the request enters the new message system.
create or replace function public.request_attendance_adjustment(
  p_access_token uuid,p_work_session_id uuid,p_clock_in_time time,p_clock_out_time time
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_login public.work_sessions%rowtype;v_target public.work_sessions%rowtype;v_employee_name text;v_timezone text;
  v_requested_clock_in_at timestamptz;v_requested_clock_out_at timestamptz;v_request_id uuid;v_message_id uuid;v_message text;
begin
  select s.* into v_login from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 수정 요청할 수 있습니다.'); end if;
  select s.* into v_target from public.work_sessions s where s.id=p_work_session_id and s.property_id=v_login.property_id
    and s.employee_id=v_login.employee_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 근무 기록을 찾을 수 없습니다.'); end if;
  select p.timezone into v_timezone from public.properties p where p.id=v_target.property_id;
  if p_clock_in_time is null or p_clock_out_time is null then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  v_requested_clock_in_at:=(v_target.work_date+p_clock_in_time) at time zone v_timezone;
  v_requested_clock_out_at:=(v_target.work_date+p_clock_out_time+case when p_clock_out_time<=p_clock_in_time then interval '1 day' else interval '0' end) at time zone v_timezone;
  if v_requested_clock_out_at-v_requested_clock_in_at>interval '24 hours' then return jsonb_build_object('ok',false,'code','invalid_time','message','근무 시작·종료 시간을 확인해주세요.'); end if;
  if exists(select 1 from public.attendance_adjustment_requests r where r.work_session_id=v_target.id) then
    return jsonb_build_object('ok',false,'code','already_requested','message','이미 제출된 수정 요청이 있습니다.');
  end if;
  insert into public.attendance_adjustment_requests(business_id,property_id,employee_id,work_session_id,
    original_clock_in_at,original_clock_out_at,requested_clock_in_at,requested_clock_out_at)
  values(v_target.business_id,v_target.property_id,v_target.employee_id,v_target.id,v_target.clock_in_at,v_target.clock_out_at,
    v_requested_clock_in_at,v_requested_clock_out_at) returning id into v_request_id;
  select e.display_name into v_employee_name from public.employees e where e.id=v_target.employee_id;
  v_message:=format(E'출퇴근 시간 수정 요청\n근무일: %s\n기존: %s ~ %s\n요청: %s ~ %s',v_target.work_date,
    to_char(v_target.clock_in_at at time zone v_timezone,'HH24:MI'),coalesce(to_char(v_target.clock_out_at at time zone v_timezone,'HH24:MI'),'-'),
    to_char(v_requested_clock_in_at at time zone v_timezone,'HH24:MI'),to_char(v_requested_clock_out_at at time zone v_timezone,'HH24:MI'));
  insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type,attendance_request_id)
  values(v_target.business_id,v_target.property_id,'staff',v_target.employee_id,v_message,'normal','attendance_approval',v_request_id)
  returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.property_id=v_target.property_id and o.active;
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
  select * into v_request from public.attendance_adjustment_requests where id=p_request_id and property_id=v_property_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정 요청을 찾을 수 없습니다.'); end if;
  if v_request.status='approved' then return jsonb_build_object('ok',true,'status','approved','already_approved',true); end if;
  update public.work_sessions set clock_in_at=v_request.requested_clock_in_at,clock_out_at=v_request.requested_clock_out_at,status='completed'
    where id=v_request.work_session_id and property_id=v_property_id;
  update public.attendance_adjustment_requests set status='approved',approved_at=clock_timestamp(),approved_by=v_owner_id where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
    from public.property_messages m where r.message_id=m.id and m.attendance_request_id=v_request.id and r.owner_id=v_owner_id;
  return jsonb_build_object('ok',true,'status','approved');
end;
$$;

revoke all on function public.send_property_message(uuid,uuid[],boolean,text,text,text),
  public.list_property_messages(uuid),public.mark_property_message_read(uuid,uuid),
  public.get_message_push_dispatch(uuid,uuid),public.send_urgent_message(uuid,text),
  public.request_attendance_adjustment(uuid,uuid,time,time),public.approve_attendance_adjustment(uuid,uuid) from public;
grant execute on function public.send_property_message(uuid,uuid[],boolean,text,text,text),
  public.list_property_messages(uuid),public.mark_property_message_read(uuid,uuid),
  public.get_message_push_dispatch(uuid,uuid),public.send_urgent_message(uuid,text),
  public.request_attendance_adjustment(uuid,uuid,time,time),public.approve_attendance_adjustment(uuid,uuid) to anon,authenticated;

commit;
select '양방향 메세지·복수수신자·읽음상태 준비 완료' as result;
