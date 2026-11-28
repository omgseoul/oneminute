begin;

CREATE OR REPLACE FUNCTION omg_private.ai_manual_data(rows jsonb, room text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 with entries as(select n,v,coalesce(nullif(btrim(v->>'rooms'),''),'전체') scope,omg_private.ai_room_key(room) roomkey from jsonb_array_elements(rows) with ordinality x(v,n)),
 candidates as(select *,scope='전체' common,exists(select from regexp_split_to_table(scope,'[,，;、\n]+')t where omg_private.ai_room_key(t)=roomkey and roomkey<>'') matched from entries)
 select coalesce(jsonb_agg(jsonb_build_object('id',n::text,'number',v->>'number','category',v->>'category','title',v->>'title','rooms',scope,'answer',v->>'answer') order by n),'[]') from candidates c
 where nullif(btrim(v->>'answer'),'') is not null and (matched or common) and not (common and exists(select from candidates s where s.scope<>'전체' and lower(btrim(s.v->>'title'))=lower(btrim(c.v->>'title')) and (s.matched or c.roomkey='')))
$function$;

CREATE OR REPLACE FUNCTION omg_private.ai_finish(p_id uuid, p_lease uuid, p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j omg_private.ai_jobs%rowtype;r public.guest_chat_rooms%rowtype;cost bigint;it bigint;ot bigint;ct bigint;wt bigint;ev uuid;disposition text;txt text;why text;v_estimated boolean;begin
 select * into j from omg_private.ai_jobs where id=p_id;if not found then return jsonb_build_object('ok',false);end if;
 select * into r from public.guest_chat_rooms where id=j.room_id for update;
 select * into j from omg_private.ai_jobs where id=p_id for update;
 if j.status<>'leased' or j.lease_id is distinct from p_lease then return jsonb_build_object('ok',true,'already_finished',true);end if;
 perform 1 from omg_private.ai_wallets where property_id=j.property_id for update;
 v_estimated:=coalesce((p_result->>'estimated')::boolean,false);it:=greatest(0,coalesce((p_result->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((p_result->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((p_result->>'cached_tokens')::bigint,0)));
 wt:=least(it-ct,greatest(0,coalesce((p_result->>'cache_write_tokens')::bigint,0)));
 cost:=case when v_estimated then j.reserved_micro else ceil((it-ct-wt)*0.10+ct*0.01+wt*0.125+ot*0.50)::bigint end;
 -- The documented rate and a byte-count upper bound reserve enough for this model.
 -- If a provider violates that bound, debit only the reserved amount and flag review.
 if cost>j.reserved_micro then cost:=j.reserved_micro;v_estimated:=true;end if;
 update omg_private.ai_wallets set balance_micro=balance_micro-cost,updated_at=now() where property_id=j.property_id;
 update omg_private.ai_usage_month set reserved_micro=reserved_micro-j.reserved_micro,used_micro=used_micro+cost,responses=responses+case when cost>0 then 1 else 0 end,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=j.property_id and month=j.period;
 disposition:=coalesce(p_result->>'disposition','handoff');why:=left(coalesce(p_result->>'reason','직원 확인이 필요합니다.'),500);txt:=left(btrim(coalesce(p_result->>'reply','')),4000);
 if r.assigned_key is not null or r.ai_paused or r.status<>'open' or r.expires_at<=now() or not omg_private.ai_active(r.property_id) then
  update omg_private.ai_jobs set status='cancelled',reason='직원 대응 또는 자동답변 조건 변경',charged_micro=cost,input_tokens=it,output_tokens=ot,cached_tokens=ct,cache_write_tokens=wt,estimated=v_estimated,provider_response_id=p_result->>'response_id',finished_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'discarded',true);
 end if;
 if disposition not in('answer','handoff','urgent') or txt='' then disposition:='handoff';txt:='';end if;
 if disposition='handoff' or coalesce(p_result->>'alert_kind',case when disposition='urgent' then 'emergency' when disposition='handoff' then 'handoff' else 'none' end) in('handoff','emergency') then
  ev:=omg_private.ai_alert(r.id,j.message_id,coalesce(p_result->>'alert_kind',case when disposition='urgent' then 'emergency' else 'handoff' end)='emergency',why);
 end if;
 if disposition in('answer','urgent') and txt<>'' then
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values(r.id,j.id,'ai:oms','OMS AI','ai',txt) on conflict(room_id,sender_key,client_id) do nothing;
 update public.guest_chat_rooms set updated_at=now() where id=r.id;
 end if;
 update omg_private.ai_jobs set status=case when disposition='answer' then 'completed' else 'handoff' end,reason=why,reply_topic=case when disposition='answer' then left(nullif(btrim(p_result->>'reply_topic'),''),120) end,charged_micro=cost,input_tokens=it,output_tokens=ot,cached_tokens=ct,cache_write_tokens=wt,estimated=v_estimated,provider_response_id=p_result->>'response_id',finished_at=now() where id=j.id;
 return jsonb_build_object('ok',true,'event_id',ev);
end$function$;

CREATE OR REPLACE FUNCTION public.save_guest_chat_alert_schedules(p_access_token uuid, p_actor_key text, p_schedules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare home uuid;item jsonb;normalized jsonb:='[]'::jsonb;first_rule jsonb;
 props uuid[];rule_days integer[];st time;et time;rule_id uuid;mode text;fields jsonb;old_schedules jsonb;
begin
 select o.property_id into home from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token)
 and s.token_expires_at>clock_timestamp() and o.active;
 if home is null then raise exception '관리자 로그인이 필요합니다.';end if;
 if not exists(select 1 from public.employees where 'employee:'||id=p_actor_key and property_id=home and active)
 and not exists(select 1 from public.owners where 'owner:'||id=p_actor_key and property_id=home and active)
 then raise exception '자기 지점 계정만 설정할 수 있습니다.';end if;
 if jsonb_typeof(p_schedules)<>'array' or jsonb_array_length(p_schedules) not between 1 and 8
 then raise exception '알림 설정은 1개부터 8개까지 저장할 수 있습니다.';end if;
 select schedules into old_schedules from public.guest_chat_alert_preferences where actor_key=p_actor_key;
 for item in select value from jsonb_array_elements(p_schedules) loop
  rule_id:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
  fields:=coalesce(item->'fields',(select old->'fields' from jsonb_array_elements(old_schedules)old where old->>'id'=rule_id::text),'["onsite_guest","online_guest","same_day_booking"]'::jsonb);
  if jsonb_typeof(fields)<>'array' then raise exception '알림 허용 분야를 확인해주세요.';end if;
  if exists(select 1 from jsonb_array_elements_text(fields)x where x not in('onsite_guest','online_guest','same_day_booking')) then raise exception '알림 허용 분야를 확인해주세요.';end if;
  mode:=coalesce(item->>'alert_mode','urgent');
  if mode not in ('weak','normal','strong','urgent') then raise exception '알림 방식을 선택해주세요.';end if;
  select coalesce(array_agg(value::uuid),'{}') into props from jsonb_array_elements_text(coalesce(item->'property_ids','[]'::jsonb));
  if coalesce((item->>'enabled')::boolean,false) and cardinality(props)=0 then raise exception '알림 받을 지점을 선택해주세요.';end if;
  if exists(select 1 from unnest(props)x where not omg_private.guest_can_access(home,x)) then raise exception '공유 승인된 지점만 선택할 수 있습니다.';end if;
  select coalesce(array_agg(value::integer),'{}') into rule_days from jsonb_array_elements_text(coalesce(item->'days','[]'::jsonb));
  if not rule_days<@array[0,1,2,3,4,5,6] or cardinality(rule_days)=0 then raise exception '알림 요일을 선택해주세요.';end if;
  st:=nullif(item->>'start_time','')::time;et:=nullif(item->>'end_time','')::time;
  if (st is null)<>(et is null) then raise exception '시작·종료 시간을 모두 입력해주세요.';end if;
  normalized:=normalized||jsonb_build_array(jsonb_build_object(
   'lower_ai_reply',coalesce((item->>'lower_ai_reply')::boolean,(select (old->>'lower_ai_reply')::boolean from jsonb_array_elements(old_schedules)old where old->>'id'=rule_id::text),false),'fields',fields,'id',rule_id,'enabled',coalesce((item->>'enabled')::boolean,false),'alert_mode',mode,
   'property_ids',to_jsonb(props),'days',to_jsonb(rule_days),
   'start_time',coalesce(to_char(st,'HH24:MI'),''),'end_time',coalesce(to_char(et,'HH24:MI'),'')));
 end loop;
 first_rule:=normalized->0;
 insert into public.guest_chat_alert_preferences(actor_key,home_property_id,enabled,property_ids,days,start_time,end_time,alert_mode,schedules)
 values(p_actor_key,home,(first_rule->>'enabled')::boolean,
  array(select value::uuid from jsonb_array_elements_text(first_rule->'property_ids')),
  array(select value::integer from jsonb_array_elements_text(first_rule->'days')),
  nullif(first_rule->>'start_time','')::time,nullif(first_rule->>'end_time','')::time,
  first_rule->>'alert_mode',normalized)
 on conflict(actor_key) do update set enabled=excluded.enabled,property_ids=excluded.property_ids,
  days=excluded.days,start_time=excluded.start_time,end_time=excluded.end_time,
  alert_mode=excluded.alert_mode,schedules=excluded.schedules,updated_at=now()
 where guest_chat_alert_preferences.home_property_id=home;
 return jsonb_build_object('ok',true,'schedules',normalized);
end$function$;

create or replace function omg_private.online_ai_notice(prop uuid, notice uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare m omg_private.online_messages%rowtype; d omg_private.online_outbox%rowtype; enabled boolean;
begin
 select * into m from omg_private.online_messages where property_id=prop and notice_id=notice;
 if not found then return '{}'::jsonb;end if;
 select * into d from omg_private.online_outbox where property_id=prop and booking_id=m.booking_id and based_on=m.id and actor='ai:automatic' and kind='ai' order by created_at desc limit 1;
 if found and d.status='sent' then return jsonb_build_object('ai_status','completed','ai_reply',d.body);end if;
 select c.ai_mode='automatic' and s.online_enabled and m.sent_at>=greatest(c.ai_automatic_at,s.online_enabled_at) into enabled from omg_private.online_connections c join omg_private.ai_settings s using(property_id) where c.property_id=prop;
 if not coalesce(enabled,false) and d.id is null then return '{}'::jsonb;end if;
 if m.created_at>now()-interval '90 seconds' and (d.status in('generating','sending') or d.id is null and omg_private.online_ai_eligible(prop,m.booking_id,m.id)) then return jsonb_build_object('ai_status','pending');end if;
 return jsonb_build_object('ai_status','unavailable');
end $$;

create or replace function omg_private.ai_completed_alert_mode(actor text, prop uuid, requested text, outcome text, at_time timestamptz default now()) returns text
language plpgsql stable security definer set search_path='' as $$
declare pref public.guest_chat_alert_preferences%rowtype;local_at timestamp;lower_enabled boolean;rank integer;
begin
 if outcome is distinct from 'completed' then return requested;end if;
 rank:=array_position(array['weak','normal','strong','urgent'],requested);
 if rank is null then return requested;end if;
 select * into pref from public.guest_chat_alert_preferences where actor_key=actor;
 if not found then return requested;end if;
 select at_time at time zone coalesce(timezone,'Asia/Seoul') into local_at from public.properties where id=pref.home_property_id;
 select bool_and(coalesce((s->>'lower_ai_reply')::boolean,false)) into lower_enabled from jsonb_array_elements(coalesce(pref.schedules,'[]'))s
 where coalesce((s->>'enabled')::boolean,false)
 and coalesce(s->'fields','["onsite_guest","online_guest","same_day_booking"]'::jsonb)?'online_guest'
 and s->'property_ids'?prop::text
 and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local_at::time<(s->>'end_time')::time then extract(dow from local_at-interval '1 day')::int else extract(dow from local_at)::int end)=any(array(select value::int from jsonb_array_elements_text(s->'days')))
 and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
 or ((s->>'start_time')::time<(s->>'end_time')::time and local_at::time>=(s->>'start_time')::time and local_at::time<(s->>'end_time')::time)
 or ((s->>'start_time')::time>(s->>'end_time')::time and (local_at::time>=(s->>'start_time')::time or local_at::time<(s->>'end_time')::time)));
 return case when lower_enabled then (array['weak','normal','strong','urgent'])[greatest(1,rank-1)] else requested end;
end $$;

CREATE OR REPLACE FUNCTION omg_private.guest_popup_online(prop uuid, notice uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select jsonb_build_object('kind','online','guest',left(coalesce(b.guest_name,'예약 #'||om.booking_id),120),'room',left(coalesce(b.room_name,'객실 미정'),60),'arrival',b.arrival,'departure',b.departure,'property',left(p.name,3),'channel',left(coalesce(b.channel,''),80),'sent',to_char(om.sent_at at time zone coalesce(p.timezone,'Asia/Seoul'),'MM.DD HH24:MI'))
 ||omg_private.online_ai_notice($1,$2)
 ||case when translated.translated is not null then jsonb_build_object('translation',translated.translated,'original',om.body,'target',c.incoming_translation_language) else '{}'::jsonb end
 from omg_private.online_messages om join public.properties p on p.id=om.property_id left join omg_private.online_bookings b on b.property_id=om.property_id and b.id=om.booking_id
 left join omg_private.online_connections c on c.property_id=om.property_id
 left join lateral(select j.translated from omg_private.translation_jobs j where j.property_id=om.property_id and j.booking_id=om.booking_id and j.message_id=om.id and j.body=om.body and j.body_hash=md5(om.body) and j.direction='incoming' and j.status='done' and j.target=c.incoming_translation_language and c.auto_translate and j.translated<>om.body and coalesce(omg_private.translation_language(j.source_language),'')<>omg_private.translation_language(c.incoming_translation_language) and not(coalesce(omg_private.translation_language(j.source_language),'')=any(c.translation_excluded_languages)) order by j.updated_at desc limit 1)translated on true
 where om.property_id=$1 and om.notice_id=$2 limit 1
$function$;

CREATE OR REPLACE FUNCTION public.get_online_push_dispatch(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m record;topics jsonb;modes jsonb;cfg jsonb;bid bigint;ai jsonb;begin
 select msg.*,p.management_number into m from public.property_messages msg join public.properties p on p.id=msg.property_id where msg.id=p_message_id and msg.source in('beds24','beds24_booking');
 if not found then return jsonb_build_object('ok',false);end if;
 if m.source='beds24_booking' then
  select same_day_alert into cfg from omg_private.online_connections where property_id=m.property_id;
  select booking_id into bid from omg_private.online_booking_notices where message_id=m.id and property_id=m.property_id;
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
   select o.topic,cfg->>'owner_mode' mode from public.property_message_recipients r join omg_private.booking_alert_owners(m.property_id) o on o.owner_id=r.owner_id where r.message_id=m.id and r.recipient_type='owner' and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_owner')::boolean,false)
   union select 'property_'||m.management_number||'_employee_'||r.employee_id,cfg->>'staff_mode' from public.property_message_recipients r join public.employees e on e.id=r.employee_id where r.message_id=m.id and r.recipient_type='staff' and e.active and e.property_id=m.property_id and coalesce((cfg->>'enabled')::boolean,false) and coalesce((cfg->>'notify_staff')::boolean,false) and exists(select 1 from public.work_sessions w where w.employee_id=e.id and w.property_id=m.property_id and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now())
  )x;
  return omg_private.filter_staff_dispatch(jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-BOOKING:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'guest_context',omg_private.guest_popup_booking(m.property_id,m.id),'sender_label','당일 예약 발생','priority','normal','route','messages.html#bot'),m.property_id,'same_day_booking');
 end if;
 select booking_id into bid from omg_private.online_messages where property_id=m.property_id and notice_id=m.id limit 1;
 if bid is null then return jsonb_build_object('ok',false);end if;
 ai:=omg_private.online_ai_notice(m.property_id,m.id);
 if ai->>'ai_status'='pending' then return jsonb_build_object('ok',false,'pending',true);end if;
 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from(
  select case when t.recipient_type='owner' then (select ao.topic from omg_private.booking_alert_owners(m.property_id) ao where ao.owner_id=t.owner_id) else 'property_'||m.management_number||'_employee_'||t.employee_id end topic,omg_private.ai_completed_alert_mode(t.recipient_key,m.property_id,t.mode,ai->>'ai_status') mode
  from omg_private.online_message_alert_recipients(m.property_id,bid) t join public.property_message_recipients r on r.message_id=m.id and r.recipient_key=t.recipient_key and r.recipient_type=t.recipient_type and r.owner_id is not distinct from t.owner_id and r.employee_id is not distinct from t.employee_id
 )x;
 return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-ONLINE:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'guest_context',omg_private.guest_popup_online(m.property_id,m.id),'route','online.html#thread/'||(select booking_id from omg_private.online_messages where notice_id=m.id limit 1)||'?property='||m.property_id);
end$function$;

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
      'property_id',p.id,'property_name',p.name,'base_name',o.display_name,'profile_image',o.profile_image,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'property_name',p.name,'base_name',e.display_name,'profile_image',e.profile_image,'work_state',omg_private.target_work_state(e.id),'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
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
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'property_id',m.property_id,'iot_booking',case when v_is_owner and m.source='iot_lock' then omg_private.iot_notice_context(m.id,m.property_id) else null end,'auto_message',case when v_is_owner and m.source='auto_message' then omg_private.auto_message_notice_context(m.id,m.property_id) else null end,'guest_context',case when m.source='beds24' then omg_private.guest_popup_online(m.property_id,m.id) when m.source='beds24_booking' then omg_private.guest_popup_booking(m.property_id,m.id) else null end,'online_popup_allowed',case when m.source='beds24' then coalesce(omg_private.online_ai_notice(m.property_id,m.id)->>'ai_status','')<>'pending' and exists(select 1 from omg_private.online_messages om cross join lateral omg_private.online_message_alert_recipients(m.property_id,om.booking_id) target where om.property_id=m.property_id and om.notice_id=m.id and omg_private.ai_completed_alert_mode(target.recipient_key,m.property_id,target.mode,omg_private.online_ai_notice(m.property_id,m.id)->>'ai_status')<>'weak' and ((v_is_owner and target.owner_id=v_owner_id) or (not v_is_owner and target.employee_id=v_employee_id))) else true end and (v_is_owner or m.source is null or m.source not in('beds24','beds24_booking','guest_ai') or coalesce(omg_private.staff_message_popup_mode(m.id,v_employee_id)<>'weak',false)),'is_platform_system_notice',coalesce(m.source='platform_system',false),'message',m.message,'priority',m.priority,'message_type',case when m.source='work_confirmation' then 'work_confirmation' else m.message_type end,'require_signature',m.require_signature,'require_understanding',m.require_understanding,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.source='reminder' then case when m.message like 'To do 알림%' then 'To do 알림' else '일정 알림' end
      when m.source='auto_message' then '자동메시지' when m.source='iot_lock' then '도어락' when m.sender_type='system' then '근태관리' else '시스템' end,
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
$function$;

revoke all on function omg_private.online_ai_notice(uuid,uuid) from public,anon,authenticated;

grant execute on function omg_private.online_ai_notice(uuid,uuid) to service_role;

revoke all on function omg_private.ai_completed_alert_mode(text,uuid,text,text,timestamptz) from public,anon,authenticated;

grant execute on function omg_private.ai_completed_alert_mode(text,uuid,text,text,timestamptz) to service_role;

commit;
