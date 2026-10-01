-- Expose the authorized property on each message, conversation and report for the shared top filter.
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
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
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
    'approval_status',coalesce(ar.status,psr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$$;

create or replace function public.staff_chat_rpc(p_access_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;actor text;peerkey text:=p_data->>'peer';result jsonb;items jsonb;person jsonb;allowed jsonb;
 client uuid;mid uuid;old omg_private.staff_chat_sends%rowtype;ids uuid[];lasttime timestamptz;lastid uuid;
begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if p_action='rooms' then
 with items as(select * from omg_private.staff_conversation_items(actor)),
 latest as(select distinct on(peer) * from items order by peer,created_at desc,id desc)
 select coalesce(jsonb_agg(jsonb_build_object('peer',l.peer,'name',coalesce(o.display_name,e.display_name,'이전 계정'),
 'profile_image',coalesce(o.profile_image,e.profile_image),'property_name',p.name,'property_id',p.id,'preview',l.body,'priority',l.priority,
 'updated_at',l.created_at,'unread',(select count(*) from items i where i.peer=l.peer and not i.mine and i.read_at is null))
 order by l.created_at desc,l.id desc),'[]') into result from latest l
 left join public.owners o on 'owner:'||o.id=l.peer left join public.employees e on 'employee:'||e.id=l.peer
 left join public.properties p on p.id=coalesce(o.property_id,e.property_id);
 return jsonb_build_object('ok',true,'rooms',result);
 end if;
 if p_action='resolve' then
 select i.peer into peerkey from omg_private.staff_conversation_items(actor)i where i.id=(p_data->>'message_id')::uuid order by i.peer limit 1;
 if peerkey is null then raise exception '대화를 찾을 수 없습니다.';end if;
 return jsonb_build_object('ok',true,'peer',peerkey);
 end if;
 if p_action not in('messages','read','send') then raise exception '잘못된 요청입니다.';end if;
 -- New conversations use the same recipient permissions as the original messenger.
 allowed:=public.list_property_messages(p_access_token)->'recipients';
 select j into person from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey;
 if person is null and not exists(select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey) then
 raise exception '이 대화에 접근할 수 없습니다.';end if;
 if p_action='send' then
 if person is null then raise exception '현재 이 계정에 메세지를 보낼 수 없습니다.';end if;
 client:=(p_data->>'client_id')::uuid;if client is null then raise exception '전송 번호가 필요합니다.';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor||client,0));
 select * into old from omg_private.staff_chat_sends where actor_key=actor and client_id=client;
 if found then
 if old.peer<>peerkey or old.body<>btrim(p_data->>'body') or old.priority<>coalesce(p_data->>'priority','normal') then raise exception '전송 번호가 중복되었습니다.';end if;
 return jsonb_build_object('ok',true,'message_id',old.message_id,'duplicate',true);
 end if;
 result:=public.send_shared_property_message(p_access_token,
 case when peerkey like 'employee:%' then array[(person->>'employee_id')::uuid] else '{}'::uuid[] end,
 case when peerkey like 'owner:%' then array[(person->>'owner_id')::uuid] else '{}'::uuid[] end,
 p_data->>'body',coalesce(p_data->>'priority','normal'),'general');
 if not (result->>'ok')::boolean then return result;end if;
 insert into omg_private.staff_chat_sends values(actor,client,peerkey,btrim(p_data->>'body'),coalesce(p_data->>'priority','normal'),(result->>'message_id')::uuid);
 return result;
 elsif p_action='read' then
 -- Only acknowledge IDs actually displayed, never unseen pages or notices.
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(coalesce(p_data->'ids','[]'));
 update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
 where r.recipient_key=actor and r.message_id=any(ids) and exists(
 select 1 from omg_private.staff_conversation_items(actor)i where i.peer=peerkey and not i.mine and i.id=r.message_id);
 return jsonb_build_object('ok',true);
 end if;
 with page as(select * from omg_private.staff_conversation_items(actor)i where i.peer=peerkey
 and (p_data->>'before_time' is null or (i.created_at,i.id)<((p_data->>'before_time')::timestamptz,(p_data->>'before_id')::uuid))
 and (p_data->>'after_time' is null or (i.created_at,i.id)>((p_data->>'after_time')::timestamptz,(p_data->>'after_id')::uuid))
 order by case when p_data->>'after_time' is not null then i.created_at end asc,
 case when p_data->>'after_time' is not null then i.id end asc,i.created_at desc,i.id desc limit 50)
 select coalesce(jsonb_agg(to_jsonb(page) order by created_at,id),'[]') into items from page;
 if person is null then
 select jsonb_build_object('display_name',coalesce(o.display_name,e.display_name,'이전 계정'),'profile_image',coalesce(o.profile_image,e.profile_image)) into person
 from (select peerkey k)x left join public.owners o on 'owner:'||o.id=x.k left join public.employees e on 'employee:'||e.id=x.k;
 end if;
 return jsonb_build_object('ok',true,'actor',a,'peer',person,'can_send',exists(select 1 from jsonb_array_elements(allowed)j where j->>'recipient_key'=peerkey),'messages',items);
end$$;

create or replace function public.work_report_inbox(p_access_token uuid,p_report_id uuid default null,p_before_at timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor jsonb;items jsonb;unread_count bigint:=0;unread_by_property jsonb:='{}'::jsonb;since_at timestamptz;
begin
 actor:=omg_private.guest_actor(p_access_token);
 if actor is null then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 select started_at into since_at from omg_private.report_inbox_started where id;
 if actor->>'kind'='owner' then
   select count(*) into unread_count from public.work_reports r
   where r.submitted_at>=since_at and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id)
   and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid);
   select coalesce(jsonb_object_agg(x.property_id,x.total),'{}'::jsonb) into unread_by_property from (
     select r.property_id,count(*) total from public.work_reports r
     where r.submitted_at>=since_at and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id)
       and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid)
     group by r.property_id
   )x;
 end if;
 select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]'::jsonb) into items from (
 select r.id,r.submitted_at,jsonb_build_object('report_id',r.id,'report_type',r.report_type,'submitted_at',r.submitted_at,
 'employee_name',coalesce(r.payload->>'worker',e.display_name),'profile_image',to_jsonb(e)->>'profile_image','property_name',p.name,'property_id',p.id,
 'work_date',r.payload->>'work_date','edited',r.payload ? 'edited_at',
 'preview',left(coalesce(r.payload->>'memo',''),120),
 'unread',actor->>'kind'='owner' and r.submitted_at>=since_at and not exists(
   select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid),
 'payload',case when p_report_id is not null then r.payload else null end) item
 from public.work_reports r join public.employees e on e.id=r.employee_id join public.properties p on p.id=r.property_id
 where ((actor->>'kind'='owner' and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id))
 or (actor->>'kind'='staff' and r.employee_id=(actor->>'id')::uuid and r.property_id=(actor->>'property_id')::uuid))
 and (p_report_id is null or r.id=p_report_id)
 and (p_before_at is null or (r.submitted_at,r.id)<(p_before_at,coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
 order by r.submitted_at desc,r.id desc limit 50
 )x;
 return jsonb_build_object('ok',true,'reports',items,'unread_count',unread_count,'unread_by_property',unread_by_property);
end;$$;
