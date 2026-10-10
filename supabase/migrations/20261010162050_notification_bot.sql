create table public.notification_bots (
 property_id uuid primary key references public.properties(id) on delete cascade,
 display_name text not null default 'OMS 알림' check(char_length(display_name) between 1 and 30),
 profile_image text,
 alert_mode text not null default 'normal' check(alert_mode in ('weak','normal','strong','urgent')),
 updated_at timestamptz not null default now(),
 constraint bot_image_limit check(profile_image is null or (char_length(profile_image)<=250000 and profile_image ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'))
);
alter table public.notification_bots enable row level security;
revoke all on public.notification_bots from public,anon,authenticated;
grant all on public.notification_bots to service_role;

create or replace function public.notification_bot_settings(p_access_token uuid,p_action text default 'list',p_property_id uuid default null,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_home uuid;v_owner uuid;v_employee uuid;v_target uuid;v_bot jsonb;v_bots jsonb;v_name text;v_mode text;v_image text;
begin
 select s.property_id,s.owner_id into v_home,v_owner from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if not found then
  select s.property_id,s.employee_id into v_home,v_employee from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and s.status in ('working','completed') and e.active;
  if not found then return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다.');end if;
 end if;
 if p_action='list' then
  select coalesce(jsonb_agg(jsonb_build_object('property_id',p.id,'property_name',p.name,'display_name',coalesce(b.display_name,'OMS 알림'),'profile_image',b.profile_image) order by p.management_number),'[]'::jsonb) into v_bots
  from public.properties p left join public.notification_bots b on b.property_id=p.id
  where p.id=v_home or exists(select 1 from public.property_share_requests r where r.status='approved' and 'messages'=any(r.requested_permissions)
    and ((r.requester_property_id=v_home and r.target_property_id=p.id) or (v_employee is not null and r.target_property_id=v_home and r.requester_property_id=p.id)))
   or exists(select 1 from public.property_messages m join public.property_message_recipients r on r.message_id=m.id where m.property_id=p.id and ((v_owner is not null and r.owner_id=v_owner) or (v_employee is not null and r.employee_id=v_employee)));
  return jsonb_build_object('ok',true,'bots',v_bots);
 end if;
 v_target:=coalesce(p_property_id,v_home);
 if v_owner is null or not omg_private.can_manage_shared_property(p_access_token,v_target,'account_settings') then return jsonb_build_object('ok',false,'message','계정관리 권한이 없습니다.');end if;
 if p_action='save' then
  v_name:=btrim(coalesce(p_data->>'display_name',''));v_mode:=coalesce(p_data->>'alert_mode','');v_image:=nullif(p_data->>'profile_image','');
  if char_length(v_name) not between 1 and 30 or v_mode not in ('weak','normal','strong','urgent') then return jsonb_build_object('ok',false,'message','봇 이름과 알림 강도를 확인해주세요.');end if;
  if v_image is not null and (char_length(v_image)>250000 or v_image !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then return jsonb_build_object('ok',false,'message','프로필 사진 크기와 형식을 확인해주세요.');end if;
  insert into public.notification_bots(property_id,display_name,profile_image,alert_mode) values(v_target,v_name,v_image,v_mode)
  on conflict(property_id) do update set display_name=excluded.display_name,profile_image=excluded.profile_image,alert_mode=excluded.alert_mode,updated_at=now();
 elsif p_action is distinct from 'get' then return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');end if;
 select jsonb_build_object('property_id',p.id,'display_name',coalesce(b.display_name,'OMS 알림'),'profile_image',b.profile_image,'alert_mode',coalesce(b.alert_mode,'normal')) into v_bot from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=v_target;
 return jsonb_build_object('ok',true,'bot',v_bot);
end;$$;
revoke all on function public.notification_bot_settings(uuid,text,uuid,jsonb) from public;
grant execute on function public.notification_bot_settings(uuid,text,uuid,jsonb) to anon,authenticated,service_role;


create or replace function omg_private.bot_recipient_modes(p_message_id uuid,v_bot_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_topics jsonb;v_modes jsonb;
begin
 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and e.active
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then coalesce(active.alert_mode,'urgent') else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
  from recipients r left join public.guest_chat_alert_preferences n on n.actor_key=r.actor_key
  left join lateral(
   select s->>'alert_mode' alert_mode from jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone (select timezone from public.properties where id=n.home_property_id)t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.target_property=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   order by case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end desc limit 1
  )active on true
  where n.actor_key is null or active.alert_mode is not null
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from targets;

 return jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$$;
revoke all on function omg_private.bot_recipient_modes(uuid,text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_message_push_dispatch_v2(p_access_token uuid, p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payload jsonb;v_topics jsonb;v_modes jsonb;v_bot_mode text;v_bot_name text;v_is_bot boolean;
begin
 v_payload:=public.get_message_push_dispatch(p_access_token,p_message_id);
 if not coalesce((v_payload->>'ok')::boolean,false) then return v_payload;end if;
 select m.sender_type='system' or m.message_type in ('announcement','attendance_warning','attendance_approval','property_share_approval','holiday_approval','holiday_notice') or m.message ~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]',coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림')
 into v_is_bot,v_bot_mode,v_bot_name from public.property_messages m left join public.notification_bots b on b.property_id=m.property_id where m.id=p_message_id;
 if not coalesce(v_is_bot,false) then v_bot_mode:=null;end if;

 with recipients as(
  select 'property_'||p.management_number||'_employee_'||e.id topic,'employee:'||e.id actor_key,e.property_id target_property
  from public.property_message_recipients r join public.employees e on e.id=r.employee_id join public.properties p on p.id=e.property_id
  where r.message_id=p_message_id and e.active
  and (v_payload->>'priority'<>'urgent' or exists(select 1 from public.work_sessions ws where ws.employee_id=e.id and ws.status='working' and ws.token_expires_at>clock_timestamp()))
  union all
  select 'property_'||p.management_number||'_owner_'||o.id,'owner:'||o.id,o.property_id
  from public.property_message_recipients r join public.owners o on o.id=r.owner_id join public.properties p on p.id=o.property_id
  where r.message_id=p_message_id and o.active
 ),targets as(
  select r.topic,case when v_bot_mode is null then coalesce(active.alert_mode,'urgent') else (array['weak','normal','strong','urgent'])[least(array_position(array['weak','normal','strong','urgent'],v_bot_mode),array_position(array['weak','normal','strong','urgent'],coalesce(active.alert_mode,'urgent')))] end alert_mode
  from recipients r left join public.guest_chat_alert_preferences n on n.actor_key=r.actor_key
  left join lateral(
   select s->>'alert_mode' alert_mode from jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone (select timezone from public.properties where id=n.home_property_id)t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.target_property=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   order by case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end desc limit 1
  )active on true
  where n.actor_key is null or active.alert_mode is not null
 )
 select coalesce(jsonb_agg(topic),'[]'::jsonb),coalesce(jsonb_object_agg(topic,alert_mode),'{}'::jsonb)
 into v_topics,v_modes from targets;
 if v_is_bot then v_payload:=v_payload||jsonb_build_object('sender_label',v_bot_name,'is_bot',true,'priority',case when v_bot_mode='urgent' then 'urgent' else 'normal' end);end if;
 return v_payload||jsonb_build_object('recipient_topics',v_topics,'recipient_modes',v_modes);
end;$function$

;
CREATE OR REPLACE FUNCTION public.get_reminder_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_message record;v_topics jsonb;v_mode text;v_name text;v_targets jsonb;
BEGIN
 IF current_setting('request.jwt.claim.role',true) IS DISTINCT FROM 'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT m.*,p.management_number INTO v_message FROM public.property_messages m JOIN public.properties p ON p.id=m.property_id
 WHERE m.id=p_message_id AND m.source='reminder';
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
 SELECT coalesce(jsonb_agg('property_'||v_message.management_number||'_'||
     CASE WHEN r.recipient_type='staff' THEN 'employee_'||r.employee_id ELSE 'owner_'||r.owner_id END),'[]'::jsonb)
 INTO v_topics FROM public.property_message_recipients r WHERE r.message_id=p_message_id;
 select coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림') into v_mode,v_name from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=v_message.property_id;
 v_targets:=omg_private.bot_recipient_modes(p_message_id,v_mode);
 RETURN jsonb_build_object('ok',true,'message_id',p_message_id,'message',v_message.message,'sender_label',v_name,'priority',case when v_mode='urgent' then 'urgent' else 'normal' end)||v_targets;
END $function$

;
CREATE OR REPLACE FUNCTION omg_private.staff_conversation_items(p_actor text)
 RETURNS TABLE(id uuid, peer text, body text, priority text, created_at timestamp with time zone, mine boolean, read_at timestamp with time zone, broadcast boolean)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
 select m.id,case when s.key=p_actor then r.recipient_key else s.key end,m.message,m.priority,m.created_at,
 s.key=p_actor,r.read_at,(select count(*)>1 from public.property_message_recipients rr where rr.message_id=m.id)
 from public.property_messages m
 cross join lateral(select case when m.sender_type='owner' then 'owner:'||m.sender_owner_id when m.sender_type='staff' then 'employee:'||m.sender_employee_id end key)s
 join public.property_message_recipients r on r.message_id=m.id
 where m.message_type in('general','emergency_report') and s.key is not null
 and m.message !~ '\[OMS-CONTRACT:[0-9a-f-]{36}\]'
 and (s.key=p_actor or r.recipient_key=p_actor) and s.key<>r.recipient_key;
$$;

CREATE OR REPLACE FUNCTION public.list_notification_bot_messages(p_access_token uuid, p_before_at timestamptz default null, p_before_id uuid default null)
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
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
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
      'acknowledged_at',rr.acknowledged_at) order by re.display_name) from public.property_message_recipients rr
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
revoke all on function public.list_notification_bot_messages(uuid,timestamptz,uuid) from public;
grant execute on function public.list_notification_bot_messages(uuid,timestamptz,uuid) to anon,authenticated,service_role;
