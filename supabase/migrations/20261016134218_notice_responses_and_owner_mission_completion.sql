-- Existing notices retain their original signature + understanding requirements.
alter table public.property_messages add column if not exists require_signature boolean not null default true;
alter table public.property_messages add column if not exists require_understanding boolean not null default true;
alter table public.property_message_recipients add column if not exists acknowledged_understood boolean not null default false;
alter table public.missions add column if not exists owner_completed_at timestamptz;
alter table public.missions add column if not exists owner_completed_by uuid references public.owners(id);

-- Delegate session, owner, and recipient authorization to the established send RPC.
create or replace function public.send_configured_announcement(
 p_access_token uuid,p_recipient_employee_ids uuid[],p_recipient_owner_ids uuid[],p_message text,
 p_require_signature boolean default false,p_require_understanding boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_result jsonb;
begin
 v_result:=public.send_shared_property_message(p_access_token,p_recipient_employee_ids,p_recipient_owner_ids,p_message,'normal','announcement');
 if not coalesce((v_result->>'ok')::boolean,false) then return v_result; end if;
 update public.property_messages set require_signature=coalesce(p_require_signature,false),require_understanding=coalesce(p_require_understanding,false)
 where id=(v_result->>'message_id')::uuid;
 return v_result;
end;
$function$;
revoke all on function public.send_configured_announcement(uuid,uuid[],uuid[],text,boolean,boolean) from public;
grant execute on function public.send_configured_announcement(uuid,uuid[],uuid[],text,boolean,boolean) to anon,authenticated,service_role;


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
  if v_understanding and not coalesce(p_understood,false) then return jsonb_build_object('ok',false,'code','understanding_required','message','이해했음을 체크해주세요.'); end if;
  if v_signature and btrim(coalesce(p_employee_name,''))<>v_name then return jsonb_build_object('ok',false,'code','name_mismatch','message','본인 이름을 정확히 입력해주세요.'); end if;
  update public.property_message_recipients set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_name=case when v_signature then v_name end,acknowledged_understood=v_understanding,read_at=coalesce(read_at,clock_timestamp()) where id=v_recipient_id returning acknowledged_at into v_ack_at;
  return jsonb_build_object('ok',true,'acknowledged_at',v_ack_at,'employee_name',case when v_signature then v_name end,'understood',v_understanding);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_property_message_read(p_access_token uuid, p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_type text;v_requires_ack boolean;
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
  select m.message_type,(m.require_signature or m.require_understanding) into v_type,v_requires_ack from public.property_messages m join public.property_message_recipients r on r.message_id=m.id where m.id=p_message_id and ((v_owner_id is not null and r.owner_id=v_owner_id) or (v_employee_id is not null and r.employee_id=v_employee_id));
  if v_type in('announcement','attendance_warning') and v_requires_ack and v_employee_id is not null then
    return jsonb_build_object('ok',false,'code','acknowledgement_required','message','요청된 서명 또는 이해했음 확인이 필요합니다.');
  end if;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.id=p_message_id
    and((v_owner_id is not null and r.owner_id=v_owner_id)or(v_employee_id is not null and r.employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_property_messages(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      and(e.property_id=v_property_id or exists(select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id))))
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,r.acknowledged_at current_acknowledged_at,r.acknowledged_name current_acknowledged_name,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null)
      and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',m.message_type,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.source='reminder' then case when m.message like 'To do 알림%' then 'To do 알림' else '일정 알림' end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at,'acknowledged_name',rr.acknowledged_name,'acknowledged_understood',rr.acknowledged_understood,'read_at',rr.read_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'holiday_request_id',m.holiday_request_id,'approval_status',coalesce(ar.status,psr.status,hr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date,'attendance_timezone',(select ap.timezone from public.properties ap where ap.id=ws.property_id)) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.holiday_requests hr on hr.id=m.holiday_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_notification_bot_messages(p_access_token uuid, p_before_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  select count(*)::integer into v_unread from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where (m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]') and r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,r.acknowledged_at current_acknowledged_at,r.acknowledged_name current_acknowledged_name,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where (m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]') and (p_before_at is null or (m.created_at,m.id)<(p_before_at,coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
      and ((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null)
      and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc,m.id desc limit 100)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',m.message_type,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.source='reminder' then case when m.message like 'To do 알림%' then 'To do 알림' else '일정 알림' end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at,'acknowledged_name',rr.acknowledged_name,'acknowledged_understood',rr.acknowledged_understood,'read_at',rr.read_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'holiday_request_id',m.holiday_request_id,'approval_status',coalesce(ar.status,psr.status,hr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc,m.id desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.holiday_requests hr on hr.id=m.holiday_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'unread_by_property',coalesce((select jsonb_object_agg(property_id,n) from (select m.property_id,count(*) n from public.property_message_recipients r join public.property_messages m on m.id=r.message_id where (m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]') and r.read_at is null and ((v_is_owner and r.owner_id=v_owner_id) or (not v_is_owner and r.employee_id=v_employee_id)) group by m.property_id) counts),'{}'::jsonb),'messages',v_items);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_mission(p_access_token uuid, p_mission_id uuid, p_note text DEFAULT ''::text, p_photo_data_url text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_employee_id uuid; v_property_id uuid;v_owner_id uuid; v_mission public.missions%rowtype;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    select * into v_mission from public.missions where id=p_mission_id and property_id=v_property_id and active for update;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','완료할 할일을 찾을 수 없습니다.'); end if;
    if v_mission.owner_completed_at is null then
      update public.missions set owner_completed_at=clock_timestamp(),owner_completed_by=v_owner_id,updated_at=clock_timestamp() where id=p_mission_id returning * into v_mission;
    end if;
    return jsonb_build_object('ok',true,'completed_by','관리자','completed_at',v_mission.owner_completed_at);
  end if;
  select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in ('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 완료할 수 있습니다.'); end if;
  select * into v_mission from public.missions where id=p_mission_id and property_id=v_property_id and active and (jsonb_array_length(target_employee_ids)=0 or target_employee_ids ? v_employee_id::text) for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  if v_mission.owner_completed_at is not null then return jsonb_build_object('ok',false,'code','already_completed','message','관리자가 이미 완료한 할일입니다.'); end if;
  if v_mission.completion_mode='any' and exists(select 1 from public.mission_completions where mission_id=p_mission_id) then
    return jsonb_build_object('ok',false,'code','already_completed','message','이미 다른 근무자가 완료한 할일입니다.');
  end if;
  if v_mission.photo_required and btrim(coalesce(p_photo_data_url,''))='' then return jsonb_build_object('ok',false,'code','photo_required','message','완료 사진을 올려주세요.'); end if;
  if char_length(coalesce(p_note,''))>1000 or octet_length(coalesce(p_photo_data_url,''))>30000000 or (coalesce(p_photo_data_url,'')<>'' and p_photo_data_url not like 'data:image/%' and p_photo_data_url not like 'data:video/webm;base64,%') then return jsonb_build_object('ok',false,'code','too_large','message','메모 또는 첨부 파일 용량을 줄여주세요.'); end if;
  insert into public.mission_completions(mission_id,employee_id,note,photo_data_url) values(p_mission_id,v_employee_id,coalesce(p_note,''),coalesce(p_photo_data_url,'')) on conflict(mission_id,employee_id) do update set note=excluded.note,photo_data_url=excluded.photo_data_url,completed_at=clock_timestamp();
  return jsonb_build_object('ok',true);
end; $function$
;

CREATE OR REPLACE FUNCTION public.list_missions(p_access_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb;v_employees jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name) order by e.created_at,e.id),'[]'::jsonb)
  into v_employees from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'title',m.title,'description',m.description,'description_photo',m.description_photo,'timing',m.timing,'priority',m.priority,
    'creator_type',m.creator_type,'creator_name',case when m.creator_type='owner' then '관리자' else coalesce(creator.display_name,'근무자') end,
    'owner_completed_at',m.owner_completed_at,'owner_completed_by',m.owner_completed_by,'completion_mode',m.completion_mode,'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then '' else coalesce(c.photo_data_url,'') end,
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',case when v_is_owner or m.completion_mode='any' then coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) else '[]'::jsonb end || case when m.owner_completed_at is not null then jsonb_build_array(jsonb_build_object('employee_id',null,'owner_id',m.owner_completed_by,'employee_name','관리자','completer_type','owner','note','관리자가 완료했습니다.','photo','','completed_at',m.owner_completed_at)) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m left join public.employees creator on creator.id=m.creator_employee_id
  left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',v_is_owner);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_shared_missions(p_access_token uuid, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'owner_completed_at',m.owner_completed_at,'owner_completed_by',m.owner_completed_by,'completion_mode',m.completion_mode,'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'due_at',m.due_at,'created_at',m.created_at,'completed_at',null,'completion_note',null,'completion_photo','',
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,
      'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc
      join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) || case when m.owner_completed_at is not null then jsonb_build_array(jsonb_build_object('employee_id',null,'owner_id',m.owner_completed_by,'employee_name','관리자','completer_type','owner','note','관리자가 완료했습니다.','photo','','completed_at',m.owner_completed_at)) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp()) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb) into v_items
  from public.missions m join public.properties p on p.id=m.property_id left join public.employees creator on creator.id=m.creator_employee_id
  where m.property_id=any(v_ids) and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',true);
end;
$function$
;

CREATE OR REPLACE FUNCTION omg_private.enqueue_due_reminders()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_setting record;v_schedule record;v_item record;v_message_id uuid;v_count integer:=0;v_offset integer;v_send_time time;v_recipient_count integer;v_secret text;v_url text;
BEGIN
 SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='omg_guest_email_worker_secret' LIMIT 1;
 IF v_secret IS NULL THEN RAISE EXCEPTION 'reminder worker secret unavailable'; END IF;
 FOR v_setting IN
  SELECT s.*,p.business_id,p.management_number,p.timezone,(clock_timestamp() AT TIME ZONE coalesce(p.timezone,'Asia/Seoul'))::date AS local_today
  FROM public.property_reminder_settings s JOIN public.properties p ON p.id=s.property_id
  WHERE jsonb_array_length(s.schedules)>0 AND (s.notify_staff OR s.notify_owner)
 LOOP
  FOR v_schedule IN SELECT (x.value->>'offset_days')::integer offset_days,(x.value->>'send_time')::time send_time FROM jsonb_array_elements(v_setting.schedules) x(value)
    WHERE to_char(clock_timestamp() AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'),'HH24:MI')=x.value->>'send_time'
  LOOP
   v_offset:=v_schedule.offset_days;v_send_time:=v_schedule.send_time;
   FOR v_item IN
    SELECT 'todo'::text AS kind,m.id,m.title,m.due_at AS due_at,m.target_employee_ids AS targets,true AS owner_target
      FROM public.missions m WHERE v_setting.kind='todo' AND m.property_id=v_setting.property_id AND m.active AND m.owner_completed_at IS NULL AND m.due_at IS NOT NULL
    UNION ALL
    SELECT 'calendar',c.id,c.title,c.start_at,to_jsonb(c.target_employee_ids),c.owner_target
      FROM public.calendar_events c WHERE v_setting.kind='calendar' AND c.property_id=v_setting.property_id AND c.holiday_request_id IS NULL
   LOOP
    IF (v_item.due_at AT TIME ZONE coalesce(v_setting.timezone,'Asia/Seoul'))::date<>v_setting.local_today+v_offset THEN CONTINUE; END IF;
    INSERT INTO public.reminder_deliveries(kind,item_id,offset_days,send_time) VALUES(v_item.kind,v_item.id,v_offset,v_send_time) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN CONTINUE; END IF;
    INSERT INTO public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source)
    VALUES(v_setting.business_id,v_setting.property_id,'system',(CASE WHEN v_item.kind='todo' THEN 'To do 알림' ELSE '일정 알림' END)||E'\n'||(CASE WHEN v_offset=0 THEN '오늘: ' WHEN v_offset=1 THEN '내일: ' ELSE v_offset||'일 후: ' END)||left(v_item.title,120),'normal','general','reminder') RETURNING id INTO v_message_id;
    IF v_setting.notify_staff THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
      SELECT v_message_id,'employee:'||e.id,'staff',e.id FROM public.employees e
      WHERE e.property_id=v_setting.property_id AND e.active AND e.role<>'owner'
       AND (v_item.kind='todo' AND (jsonb_array_length(coalesce(v_item.targets,'[]'::jsonb))=0 OR to_jsonb(e.id)<@v_item.targets) OR v_item.kind='calendar' AND to_jsonb(e.id)<@v_item.targets)
      ON CONFLICT DO NOTHING;
    END IF;
    IF v_setting.notify_owner THEN
      INSERT INTO public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
      SELECT v_message_id,'owner:'||o.id,'owner',o.id FROM public.owners o WHERE o.property_id=v_setting.property_id AND o.active ON CONFLICT DO NOTHING;
    END IF;
    SELECT count(*) INTO v_recipient_count FROM public.property_message_recipients WHERE message_id=v_message_id;
    IF v_recipient_count=0 THEN
      DELETE FROM public.reminder_deliveries WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND send_time=v_send_time AND message_id IS NULL;
      DELETE FROM public.property_messages WHERE id=v_message_id;CONTINUE;
    END IF;
    UPDATE public.reminder_deliveries SET message_id=v_message_id WHERE kind=v_item.kind AND item_id=v_item.id AND offset_days=v_offset AND send_time=v_send_time;
    v_url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/dispatch-notification/reminder';
    PERFORM net.http_post(url:=v_url,headers:=jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),body:=jsonb_build_object('message_id',v_message_id));v_count:=v_count+1;
   END LOOP;
  END LOOP;
 END LOOP;
 RETURN v_count;
END $function$
;

CREATE OR REPLACE FUNCTION public.list_overdue_calendar_tasks(p_access_token uuid, p_property_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_property_id uuid;v_employee_id uuid;v_owner boolean:=false;v_properties uuid[];v_tasks jsonb;
begin
 select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if found then v_owner:=true;
 else
  select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 end if;
 if v_owner then
  v_properties:=coalesce(nullif(p_property_ids,array[]::uuid[]),array[v_property_id]);
  if cardinality(v_properties)>20 or exists(select 1 from unnest(v_properties) requested(id) where requested.id<>v_property_id and not omg_private.can_manage_shared_property(p_access_token,requested.id,'missions')) then
   return jsonb_build_object('ok',false,'message','숙소 권한을 확인해주세요.');
  end if;
 else v_properties:=array[v_property_id];
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids) order by m.due_at,m.created_at),'[]'::jsonb)
 into v_tasks
 from public.missions m join public.properties p on p.id=m.property_id
 where m.property_id=any(v_properties) and m.active and m.owner_completed_at is null and m.creator_type='owner' and m.due_at<clock_timestamp()
  and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text);
 return jsonb_build_object('ok',true,'tasks',v_tasks);
end$function$
;

CREATE OR REPLACE FUNCTION public.list_shared_calendar_board(p_access_token uuid, p_property_ids uuid[], p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_own uuid;v_events jsonb;v_tasks jsonb;
BEGIN
 SELECT s.property_id INTO v_own FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_access_token) AND s.token_expires_at>clock_timestamp() AND o.active;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'message','관리자 로그인 후 이용해주세요.'); END IF;
 IF cardinality(p_property_ids) NOT BETWEEN 1 AND 20 OR p_from IS NULL OR p_to<=p_from OR p_to-p_from>interval '62 days'
    OR EXISTS(SELECT 1 FROM unnest(p_property_ids) id WHERE NOT omg_private.can_manage_shared_property(p_access_token,id,'missions')) THEN
   RETURN jsonb_build_object('ok',false,'message','조회 기간 또는 숙소 권한을 확인해주세요.');
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',c.id,'property_id',c.property_id,'property_name',p.name,'title',c.title,'details',c.details,'start_at',c.start_at,'end_at',c.end_at,
   'all_day',c.all_day,'owner_target',c.owner_target,'target_employee_ids',c.target_employee_ids,
   'creator_kind',c.creator_kind,'holiday_request_id',c.holiday_request_id,
   'can_edit',c.property_id=v_own AND c.holiday_request_id IS NULL,
   'target_names',coalesce((SELECT jsonb_agg(e.display_name ORDER BY e.display_name) FROM public.employees e WHERE e.id=any(c.target_employee_ids)),'[]'::jsonb)
 ) ORDER BY c.start_at,c.created_at),'[]'::jsonb) INTO v_events
 FROM public.calendar_events c JOIN public.properties p ON p.id=c.property_id
 WHERE c.property_id=any(p_property_ids) AND c.start_at<p_to AND c.end_at>p_from;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',m.id,'property_id',m.property_id,'property_name',p.name,'title',m.title,'due_at',m.due_at,
   'target_employee_ids',m.target_employee_ids) ORDER BY m.due_at,m.created_at),'[]'::jsonb) INTO v_tasks
 FROM public.missions m JOIN public.properties p ON p.id=m.property_id
 WHERE m.property_id=any(p_property_ids) AND m.active AND m.owner_completed_at IS NULL AND m.creator_type='owner' AND m.due_at>=p_from AND m.due_at<p_to;
 RETURN jsonb_build_object('ok',true,'events',v_events,'tasks',v_tasks);
END $function$
;

notify pgrst,'reload schema';
