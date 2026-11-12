-- Editable property-scoped AI escalation rules; existing DATA and preferences are preserved.
alter table omg_private.ai_settings add column if not exists handoff_config jsonb not null default '{"enabled": true, "script": "자동답변 DATA만으로 정확히 답변하거나 해결할 수 없어 직원의 확인·처리가 필요한 문의 중 비상·재난 상황이 아닌 경우 전달합니다.", "notify_staff": true, "staff_mode": "normal", "notify_owner": true, "owner_mode": "normal"}'::jsonb;
alter table omg_private.ai_settings add column if not exists emergency_config jsonb not null default '{"enabled": true, "script": "문이 열리지 않음, 문이나 객실에 갇힘, 물이 나오지 않음, 화재·연기·가스 누출, 신변 위협, 폭력·침입자 등 즉시 확인이나 조치가 필요한 상황을 전달합니다.", "notify_staff": true, "staff_mode": "urgent", "notify_owner": true, "owner_mode": "urgent"}'::jsonb;

create or replace function omg_private.ai_validate_alert_config(v jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare k text;begin
 if jsonb_typeof(v) is distinct from 'object' then raise exception '전달 설정 형식을 확인해주세요.';end if;
 foreach k in array array['enabled','notify_staff','notify_owner'] loop
  if jsonb_typeof(v->k) is distinct from 'boolean' then raise exception '전달 설정의 켜기·끄기를 확인해주세요.';end if;
 end loop;
 if jsonb_typeof(v->'script') is distinct from 'string' or length(btrim(v->>'script')) not between 1 and 2000 then raise exception '전달 판단 스크립트는 1~2,000자로 입력해주세요.';end if;
 if coalesce(v->>'staff_mode','') not in('weak','normal','strong','urgent') or coalesce(v->>'owner_mode','') not in('weak','normal','strong','urgent') then raise exception '알림 강도를 선택해주세요.';end if;
 return jsonb_build_object('enabled',(v->>'enabled')::boolean,'script',btrim(v->>'script'),'notify_staff',(v->>'notify_staff')::boolean,'staff_mode',v->>'staff_mode','notify_owner',(v->>'notify_owner')::boolean,'owner_mode',v->>'owner_mode');
end$$;
revoke all on function omg_private.ai_validate_alert_config(jsonb) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION omg_private.ai_owner(p_token uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;home uuid;rows jsonb;item jsonb;v_mode text;st time;et time;begin
 a:=omg_private.guest_actor(p_token);if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 insert into omg_private.ai_settings(property_id) values(home) on conflict do nothing;insert into omg_private.ai_wallets(property_id) values(home) on conflict do nothing;
 if p_action='save' then
  rows:=coalesce(p_data->'data','[]');v_mode:=coalesce(p_data->>'mode','always');st:=nullif(p_data->>'start_time','')::time;et:=nullif(p_data->>'end_time','')::time;
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>200 or octet_length(rows::text)>60000 then raise exception 'DATA는 200행, 총 60KB까지 입력할 수 있습니다.';end if;
  if v_mode not in('always','no_staff','schedule') or (v_mode='schedule' and(st is null or et is null or st=et)) then raise exception '사용 조건과 서로 다른 시작·종료 시간을 선택해주세요.';end if;
  if length(btrim(coalesce(p_data->>'prompt',''))) not between 1 and 8000 then raise exception '프롬프트는 1~8,000자로 입력해주세요.';end if;
  for item in select value from jsonb_array_elements(rows) loop if length(btrim(coalesce(item->>'title',''))) not between 1 and 120 or length(coalesce(item->>'answer',''))>4000 then raise exception '제목은 1~120자, 답변은 4,000자 이내로 입력해주세요.';end if;end loop;
  if coalesce((p_data->>'enabled')::boolean,false) and not exists(select 1 from jsonb_array_elements(rows)j where length(btrim(coalesce(j->>'answer','')))>0) then raise exception '자동답변 DATA를 하나 이상 입력해주세요.';end if;
  update omg_private.ai_settings set handoff_config=case when p_data ? 'handoff_config' then omg_private.ai_validate_alert_config(p_data->'handoff_config') else handoff_config end,emergency_config=case when p_data ? 'emergency_config' then omg_private.ai_validate_alert_config(p_data->'emergency_config') else emergency_config end,enabled=coalesce((p_data->>'enabled')::boolean,false),mode=v_mode,start_time=st,end_time=et,prompt=btrim(p_data->>'prompt'),data=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'answer',btrim(j->>'answer'))),'[]') from jsonb_array_elements(rows)j),revision=revision+1,updated_at=now(),updated_by=a->>'key' where property_id=home;
 elsif p_action<>'get' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'settings',(select to_jsonb(s) from omg_private.ai_settings s where property_id=home),'usage',omg_private.ai_summary(home),'default_prompt',omg_private.ai_default_prompt(),'provider_ready',exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null),'qr_enabled',exists(select 1 from public.guest_support_config where property_id=home and enabled and chat_enabled),'timezone',(select timezone from public.properties where id=home),'history',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select created_at,status,charged_micro/1000.0 credits,reason,estimated from omg_private.ai_jobs where property_id=home order by created_at desc limit 30)x));
end$function$;


CREATE OR REPLACE FUNCTION omg_private.ai_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j omg_private.ai_jobs%rowtype;r public.guest_chat_rooms%rowtype;s omg_private.ai_settings%rowtype;w omg_private.ai_wallets%rowtype;history jsonb;dataset jsonb;reservation bigint;used bigint;reserved bigint;totalreserved bigint;v_month date;ev uuid;begin
 -- Expired leases are settled once, conservatively; never make an ambiguous paid request twice.
 select * into j from omg_private.ai_jobs where status='leased' and leased_until<now() order by leased_until limit 1;
 if found then return omg_private.ai_finish(j.id,j.lease_id,jsonb_build_object('estimated',true,'disposition','handoff','reason','AI 응답 확인 시간 초과 · 예약 비용 추정 정산','reply','직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / Please wait for a staff reply.'))||jsonb_build_object('skip',true);end if;
 select q.* into j from omg_private.ai_jobs q where q.status='pending' and not exists(select 1 from omg_private.ai_jobs x where x.room_id=q.room_id and x.status='leased') order by q.created_at limit 1;
 if not found then return jsonb_build_object('ok',true,'empty',true);end if;
 select * into r from public.guest_chat_rooms where id=j.room_id for update skip locked;
 if not found then return jsonb_build_object('ok',true,'empty',true);end if;
 select * into j from omg_private.ai_jobs where id=j.id for update;
 if j.status<>'pending' or exists(select 1 from omg_private.ai_jobs x where x.room_id=r.id and x.status='leased') then return jsonb_build_object('ok',true,'skip',true);end if;
 if r.status<>'open' or r.expires_at<=now() or r.assigned_key is not null or r.ai_paused or not omg_private.ai_active(r.property_id) then
  update omg_private.ai_jobs set status='cancelled',reason='자동답변 조건 변경',finished_at=now() where id=j.id;
  if r.status='open' and not r.ai_paused and r.assigned_key is null then ev:=omg_private.ai_alert(r.id,j.message_id,false,'자동답변 사용 조건이 변경되어 직원 확인이 필요합니다.');end if;
  return jsonb_build_object('ok',true,'skip',true,'event_id',ev);
 end if;
 select * into s from omg_private.ai_settings where property_id=r.property_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.n::text,'title',x.v->>'title','answer',x.v->>'answer')),'[]') into dataset from jsonb_array_elements(s.data) with ordinality x(v,n) where btrim(coalesce(x.v->>'answer',''))<>'';
 select coalesce(jsonb_agg(jsonb_build_object('role',case when x.sender_kind='guest' then 'user' else 'assistant' end,'content',left(x.body,2000)) order by x.seq),'[]') into history from(select m.seq,m.body,m.sender_kind from public.guest_chat_messages m where m.room_id=r.id and m.seq<=(select seq from public.guest_chat_messages where id=j.message_id) and m.sender_kind in('guest','ai','staff') order by m.seq desc limit 12)x;
 -- Keep the latest question whole, including multiple questions in the same message.
 history:=jsonb_set(history,array[(jsonb_array_length(history)-1)::text,'content'],to_jsonb((select body from public.guest_chat_messages where id=j.message_id)));
 reservation:=ceil((octet_length(s.prompt)+octet_length(s.support_policy)+octet_length(s.handoff_config::text)+octet_length(s.emergency_config::text)+octet_length(dataset::text)+octet_length(history::text)+16000)*0.125+2048*0.50)::bigint;
 insert into omg_private.ai_wallets(property_id)values(r.property_id)on conflict do nothing;
 select * into w from omg_private.ai_wallets where property_id=r.property_id for update;
 v_month:=omg_private.ai_month();insert into omg_private.ai_usage_month(property_id,month)values(r.property_id,v_month)on conflict do nothing;
 select u.used_micro,u.reserved_micro into used,reserved from omg_private.ai_usage_month u where u.property_id=r.property_id and u.month=v_month;
 select coalesce(sum(reserved_micro),0) into totalreserved from omg_private.ai_jobs where property_id=r.property_id and status='leased';
 if not w.enabled or w.balance_micro-totalreserved<reservation or w.monthly_limit_micro-used-reserved<reservation or not exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null) or dataset='[]'::jsonb or j.created_at<now()-interval '5 minutes' then
  ev:=omg_private.ai_alert(r.id,j.message_id,false,'AI 연결·사용 한도 또는 응답 대기 상태를 확인해주세요.');
  insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values(r.id,j.id,'ai:oms','OMS AI','ai','현재 자동 안내가 어려워 직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / Please wait for a staff reply.')on conflict do nothing;
  update omg_private.ai_jobs set status='handoff',reason='연결 미완료·한도 부족·대기 시간 초과',finished_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'skip',true,'event_id',ev);
 end if;
 update omg_private.ai_usage_month set reserved_micro=reserved_micro+reservation where property_id=r.property_id and ai_usage_month.month=v_month;
 update omg_private.ai_jobs set status='leased',lease_id=gen_random_uuid(),leased_until=now()+interval '90 seconds',period=v_month,reserved_micro=reservation where id=j.id returning * into j;
 return jsonb_build_object('ok',true,'id',j.id,'support_policy',s.support_policy,'alert_rules',jsonb_build_object('handoff',s.handoff_config,'emergency',s.emergency_config),'lease_id',j.lease_id,'prompt',s.prompt,'data',dataset,'history',history,'has_attachment',(select asset_id is not null from public.guest_chat_messages where id=j.message_id),'reserved_micro',reservation);
end$function$;


CREATE OR REPLACE FUNCTION public.get_guest_chat_dispatch(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;alert omg_private.ai_alerts%rowtype;cfg jsonb;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;

 -- AI handles ordinary questions silently; escalation has its own durable event.
 if ev.event_kind='message' and exists(select 1 from omg_private.ai_jobs where message_id=ev.message_id and status in('pending','leased','completed','handoff')) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb);end if;
 select * into alert from omg_private.ai_alerts where event_id=ev.id;

 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
  coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
  select distinct on(c.topic)c.topic,c.alert_mode,c.valid_until from(
   select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,s->>'alert_mode' alert_mode,
    ((extract(epoch from least(ev.created_at+interval '5 minutes',
     (case when nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time' then (local.t::date+1)::timestamp
      when (s->>'start_time')::time>(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time then (local.t::date+1)+(s->>'end_time')::time
      else local.t::date+(s->>'end_time')::time end) at time zone p.timezone))*1000)::bigint)::text valid_until,
    case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end strength
   from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
   cross join lateral jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone p.timezone t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.property_id=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and omg_private.guest_can_access(n.home_property_id,r.property_id)
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   and (exists(select 1 from public.work_sessions ws join public.employees e on e.id=ws.employee_id where 'employee:'||e.id=n.actor_key and e.active and ws.status='working' and ws.token_expires_at>now())
    or exists(select 1 from public.owner_sessions os join public.owners o on o.id=os.owner_id where 'owner:'||o.id=n.actor_key and o.active and os.token_expires_at>now()))
  )c order by c.topic,c.strength desc,c.valid_until desc
 )x;
 if alert.event_id is not null then
  select case when alert.urgent then s.emergency_config else s.handoff_config end into cfg from omg_private.ai_settings s where s.property_id=r.property_id;
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.mode),'{}') into topics,modes from (
   select 'property_'||p.management_number||'_owner_'||o.id topic,cfg->>'owner_mode' mode
   from public.owners o join public.properties p on p.id=o.property_id
   where o.property_id=r.property_id and o.active and (cfg->>'enabled')::boolean and (cfg->>'notify_owner')::boolean
   union
   select 'property_'||p.management_number||'_employee_'||e.id,cfg->>'staff_mode'
   from public.work_sessions w join public.employees e on e.id=w.employee_id join public.properties p on p.id=w.property_id
   where w.property_id=r.property_id and e.property_id=r.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now()
    and (cfg->>'enabled')::boolean and (cfg->>'notify_staff')::boolean
  )x;
  deadlines:='{}'::jsonb;
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_modes',modes,'recipient_deadlines',deadlines,'message_type','guest_chat','valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,'priority',case when alert.urgent then 'urgent' else 'normal' end,'sender_label',case when alert.urgent then '긴급 AI 지원요청 · ' else 'AI 지원요청 · ' end||r.guest_name||' · '||coalesce(r.room_number,'객실 미정'),'message',alert.reason||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=alert.message_id),''));
 end if;
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat',
  'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
  'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label',r.guest_name,
  'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.') end);
end$function$;


CREATE OR REPLACE FUNCTION omg_private.ai_record_notice(p_event uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a omg_private.ai_alerts%rowtype;r public.guest_chat_rooms%rowtype;mid uuid;delivery jsonb;begin
 select * into a from omg_private.ai_alerts where event_id=p_event;
 if not found then return;end if;
 select * into r from public.guest_chat_rooms where id=a.room_id;
 select id into mid from public.property_messages where source='guest_ai' and external_message_id=p_event::text;
 if mid is not null then return;end if;
 delivery:=public.get_guest_chat_dispatch(p_event);
 if jsonb_array_length(coalesce(delivery->'recipient_topics','[]'))=0 then return;end if;
 insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
 select p.business_id,p.id,'system',
  '[OMS-GUEST-CHAT:'||r.id||']'||E'\n'||case when a.urgent then '긴급 AI 지원요청' else 'AI 메시지 지원요청' end||E'\n'||left(r.guest_name,120)||' · '||left(coalesce(r.room_number,'객실 미정'),100)||E'\n게스트 문의가 왔습니다. 직원 확인이 필요합니다.'||E'\n'||left(coalesce(a.reason,''),500)||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=a.message_id),''),
  'normal','general','guest_ai',p_event::text from public.properties p where p.id=r.property_id returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)
 select mid,'owner:'||o.id,'owner',o.id,null from public.owners o join public.properties p on p.id=o.property_id
 where o.active and delivery->'recipient_topics' ? ('property_'||p.management_number||'_owner_'||o.id)
 union all select mid,'employee:'||e.id,'staff',null,e.id from public.employees e join public.properties p on p.id=e.property_id
 where e.active and delivery->'recipient_topics' ? ('property_'||p.management_number||'_employee_'||e.id);
end$function$;


CREATE OR REPLACE FUNCTION omg_private.ai_alert(p_room uuid, p_message uuid, p_urgent boolean, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev uuid;cfg jsonb;begin
 select case when p_urgent then s.emergency_config else s.handoff_config end into cfg from omg_private.ai_settings s join public.guest_chat_rooms r on r.property_id=s.property_id where r.id=p_room;
 if cfg is not null and (not (cfg->>'enabled')::boolean or not ((cfg->>'notify_staff')::boolean or (cfg->>'notify_owner')::boolean)) then return null;end if;
 perform pg_advisory_xact_lock(hashtextextended(p_room::text,71));
 update public.guest_chat_rooms set ai_handoff=true,ai_paused=ai_paused or p_urgent,updated_at=now() where id=p_room;
 select event_id into ev from omg_private.ai_alerts where room_id=p_room and message_id is not distinct from p_message and urgent=p_urgent and created_at>now()-interval '60 seconds' order by created_at desc limit 1;
 if ev is null then
  insert into public.guest_chat_events(room_id,event_kind)values(p_room,case when p_urgent then 'ai_urgent' else 'ai_handoff' end) returning id into ev;
  insert into omg_private.ai_alerts(event_id,room_id,message_id,urgent,reason)values(ev,p_room,p_message,p_urgent,left(p_reason,500));
 end if;
 perform omg_private.ai_record_notice(ev);
 return ev;
end$function$;


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
 if disposition not in('answer','handoff','urgent') or txt='' then disposition:='handoff';txt:='정확한 안내를 위해 직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / A staff member needs to check this. Please wait for their reply.';end if;
 if coalesce(p_result->>'alert_kind',case when disposition='urgent' then 'emergency' when disposition='handoff' then 'handoff' else 'none' end) in('handoff','emergency') then
  ev:=omg_private.ai_alert(r.id,j.message_id,coalesce(p_result->>'alert_kind',case when disposition='urgent' then 'emergency' else 'handoff' end)='emergency',why);
 end if;
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values(r.id,j.id,'ai:oms','OMS AI','ai',txt) on conflict(room_id,sender_key,client_id) do nothing;
 update public.guest_chat_rooms set updated_at=now() where id=r.id;
 update omg_private.ai_jobs set status=case when disposition='answer' then 'completed' else 'handoff' end,reason=why,charged_micro=cost,input_tokens=it,output_tokens=ot,cached_tokens=ct,cache_write_tokens=wt,estimated=v_estimated,provider_response_id=p_result->>'response_id',finished_at=now() where id=j.id;
 return jsonb_build_object('ok',true,'event_id',ev);
end$function$;

