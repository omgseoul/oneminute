begin;

create or replace function public.list_working_employees(p_access_token uuid,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  select count(*)::integer into v_employee_count from public.employees e
  where e.active and e.role<>'owner' and e.id=any(v_employee_ids) and(
    e.property_id=v_property.id or exists(
      select 1 from public.property_share_requests r
      where r.status='approved' and 'messages'=any(r.requested_permissions) and(
        (r.requester_property_id=v_property.id and r.target_property_id=e.property_id)
        or(v_sender_type='staff' and r.target_property_id=v_property.id and r.requester_property_id=e.property_id)
      )
    )
  );
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
      and(e.property_id=v_property_id or exists(
        select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id)
        )
      ))
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

revoke all on function public.list_working_employees(uuid,uuid[]) from public;
revoke all on function public.send_shared_property_message(uuid,uuid[],uuid[],text,text,text) from public;
revoke all on function public.list_property_messages(uuid) from public;
grant execute on function public.list_working_employees(uuid,uuid[]) to anon,authenticated;
grant execute on function public.send_shared_property_message(uuid,uuid[],uuid[],text,text,text) to anon,authenticated;
grant execute on function public.list_property_messages(uuid) to anon,authenticated;

commit;

select '027_staff_working_status_and_messages_applied' as migration_status;
