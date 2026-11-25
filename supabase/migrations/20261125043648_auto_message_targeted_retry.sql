begin;
alter table omg_private.auto_message_deliveries add column retry_count integer not null default 0 check(retry_count>=0),add column manual_retry boolean not null default false;
alter table omg_private.auto_message_notices add column retry_count integer not null default 0 check(retry_count>=0);
alter table omg_private.auto_message_notices drop constraint auto_message_notices_delivery_id_kind_key;
alter table omg_private.auto_message_notices add constraint auto_message_notices_delivery_attempt_kind_key unique(delivery_id,retry_count,kind);
CREATE OR REPLACE FUNCTION omg_private.auto_message_owner(p_token uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb; home uuid; r omg_private.auto_message_rules%rowtype; k text; v jsonb; rid uuid; d omg_private.auto_message_deliveries%rowtype; targets jsonb; target jsonb; expected integer; results jsonb:='[]'; queued integer:=0; begin
 a:=omg_private.guest_actor(p_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 자동메시지 설정 권한이 없습니다.';end if;
 if p_action='retry' then
  targets:=p_data->'targets';
  if nullif(p_data->>'notice_id','') is not null then
   select jsonb_build_array(jsonb_build_object('id',n.delivery_id,'retry_count',n.retry_count)) into targets
   from omg_private.auto_message_notices n join omg_private.auto_message_deliveries x on x.id=n.delivery_id
   where n.message_id=(p_data->>'notice_id')::uuid and x.property_id=home and n.kind='terminal';
  end if;
  if jsonb_typeof(targets) is distinct from 'array' or jsonb_array_length(targets) not between 1 and 50 then raise exception '재전송할 실패 건을 선택해주세요.';end if;
  if exists(select 1 from jsonb_array_elements(targets) t where not exists(select 1 from omg_private.auto_message_deliveries x where x.id=(t->>'id')::uuid and x.property_id=home)) then raise exception '이 지점의 발송 기록이 아닙니다.';end if;
  -- Deterministic row locks and an expected attempt number make double taps and old notices idempotent.
  for d in select x.* from omg_private.auto_message_deliveries x where x.property_id=home and x.id in(select (t->>'id')::uuid from jsonb_array_elements(targets)t) order by x.id for update loop
   select t into target from jsonb_array_elements(targets)t where (t->>'id')::uuid=d.id limit 1;
   expected:=(target->>'retry_count')::integer;
   if d.status<>'failed' or expected is distinct from d.retry_count then
    results:=results||jsonb_build_array(jsonb_build_object('id',d.id,'queued',false,'message','이미 처리되었거나 최신 실패 기록이 아닙니다.'));
   elsif not exists(select 1 from omg_private.auto_message_rules where id=d.rule_id and enabled) then
    results:=results||jsonb_build_array(jsonb_build_object('id',d.id,'queued',false,'message','자동메시지 설정을 먼저 켜주세요.'));
   else
    update omg_private.auto_message_deliveries x set status='waiting',retry_count=x.retry_count+1,manual_retry=true,next_at=now(),lease=null,leased_until=null,error=null,language=null,
     revision=retry_rule.revision,title=retry_rule.title,updated_at=now()
    from omg_private.auto_message_rules retry_rule where x.id=d.id and retry_rule.id=x.rule_id;
    queued:=queued+1;results:=results||jsonb_build_array(jsonb_build_object('id',d.id,'queued',true,'message','이 예약의 재전송을 접수했습니다.'));
   end if;
  end loop;
 end if;
 if p_action in('save','toggle') then
  rid:=(p_data->>'id')::uuid;
  if rid is null then raise exception '메시지 식별자를 확인해주세요.';end if;
  select * into r from omg_private.auto_message_rules where id=rid for update;
  if found and r.property_id<>home then raise exception '이 지점의 메시지가 아닙니다.';end if;
  if r.id is not null and r.revision<>coalesce((p_data->>'revision')::int,0) then raise exception '다른 화면에서 수정되었습니다. 다시 열어주세요.';end if;
  if p_action='toggle' then
   if r.id is null then raise exception '메시지를 찾지 못했습니다.';end if;
   update omg_private.auto_message_rules set enabled=(p_data->>'enabled')::boolean,
    enabled_from=case when not enabled and (p_data->>'enabled')::boolean then now() else enabled_from end,
    revision=revision+1,updated_at=now() where id=rid;
  else
   if length(btrim(coalesce(p_data->>'title',''))) not between 1 and 80 then raise exception '제목을 1~80자로 입력해주세요.';end if;
   if coalesce(p_data->>'trigger','') not in('booking','booking_after','checkin_before','checkin_after') or coalesce((p_data->>'days')::integer,-1) not between 0 and 365 then raise exception '발송 시기와 일수를 확인해주세요.';end if;
   if p_data->>'trigger'='booking_after' and (p_data->>'days')::integer<1 then raise exception '예약 후는 1일부터 설정할 수 있습니다.';end if;
   if jsonb_typeof(p_data->'messages') is distinct from 'object' or length(btrim(coalesce(p_data->'messages'->>'common',''))) not between 1 and 4000 then raise exception '공통 메시지를 1~4,000자로 입력해주세요.';end if;
   for k,v in select * from jsonb_each(p_data->'messages') loop
    if k not in('common','ja','en','zh-CN','zh-TW','ko','fr','de','es','it','pt','ru','th','vi','id') or jsonb_typeof(v)<>'string' or length(btrim(v#>>'{}')) not between 1 and 4000 then raise exception '언어별 메시지를 확인해주세요.';end if;
    if exists(select 1 from regexp_matches(v#>>'{}','\{\{([^{}]+)\}\}','g') m where m[1] not in('이름','체크인','체크아웃','비밀번호','객실')) then raise exception '지원하지 않는 자동 입력 요소입니다.';end if;
   end loop;
   if coalesce((p_data->>'enabled')::boolean,false) and not exists(select 1 from omg_private.online_connections where property_id=home and vault_id is not null and beds_property_id is not null) then raise exception '먼저 이 지점의 Beds24 연결을 설정해주세요.';end if;
   insert into omg_private.auto_message_rules(id,property_id,title,trigger,days,send_time,messages,enabled)
    values(rid,home,btrim(p_data->>'title'),p_data->>'trigger',(p_data->>'days')::integer,coalesce(nullif(p_data->>'send_time','')::time,'09:00'),p_data->'messages',coalesce((p_data->>'enabled')::boolean,false))
   on conflict(id) do update set title=excluded.title,trigger=excluded.trigger,days=excluded.days,send_time=excluded.send_time,messages=excluded.messages,enabled=excluded.enabled,
    enabled_from=case when not auto_message_rules.enabled and excluded.enabled then now() else auto_message_rules.enabled_from end,
    revision=auto_message_rules.revision+1,updated_at=now();
  end if;
 elsif p_action not in('list','retry') then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'retry_queued',queued,'retry_results',results,'property_id',home,'timezone',(select timezone from public.properties where id=home),
 'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p where p.id=(a->>'property_id')::uuid or (omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages'))),
 'rules',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from omg_private.auto_message_rules x where property_id=home),
 'logs',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select log_delivery.id,log_delivery.booking_id,log_delivery.title,log_delivery.status,log_delivery.language,log_delivery.error,log_delivery.updated_at,log_delivery.retry_count,log_delivery.manual_retry,
 coalesce(nullif(btrim(regexp_replace(b.guest_name,'[0-9０-９]','','g')),''),'이름 미등록') guest_name,b.room_name,b.arrival,b.departure,b.data->>'apiReference' booking_reference,
 (log_delivery.status='failed' and exists(select 1 from omg_private.auto_message_rules log_rule where log_rule.id=log_delivery.rule_id and log_rule.enabled)) can_retry
 from omg_private.auto_message_deliveries log_delivery left join omg_private.online_bookings b on b.property_id=log_delivery.property_id and b.id=log_delivery.booking_id
 where log_delivery.property_id=home order by log_delivery.updated_at desc,log_delivery.id limit 50)x));
end$function$
;

CREATE OR REPLACE FUNCTION omg_private.auto_message_notice(p_delivery uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j omg_private.auto_message_deliveries%rowtype; b omg_private.online_bookings%rowtype; prop public.properties%rowtype;
 nid uuid; mid uuid; title text; body text; begin
 select * into j from omg_private.auto_message_deliveries where id=p_delivery;if not found then return;end if;
 insert into omg_private.auto_message_notices(delivery_id,kind,retry_count) values(j.id,p_kind,j.retry_count) on conflict(delivery_id,retry_count,kind) do nothing returning id into nid;
 if not found then return;end if;
 select * into b from omg_private.online_bookings where property_id=j.property_id and id=j.booking_id;
 select * into prop from public.properties where id=j.property_id;
 title:=case when p_kind='recovered' then '자동메시지 발송 완료' when p_kind='blocked' then '자동메시지 발송 지연' when j.status='failed' then '자동메시지 발송실패' when j.status='uncertain' then '자동메시지 발송 확인' else '자동메시지 미발송' end;
 body:='['||title||']'||E'\n'||prop.name||' · 객실 '||coalesce(nullif(b.room_name,''),'미정')||E'\n예약 #'||j.booking_id||coalesce(' · 채널 예약번호 '||nullif(b.data->>'apiReference',''),'')
  ||E'\n게스트: '||coalesce(nullif(btrim(regexp_replace(b.guest_name,'[0-9０-９]','','g')),''),'이름 미등록')
  ||case when j.retry_count>0 then E'\n재전송: '||j.retry_count||'회' else '' end||E'\n메시지: '||j.title||E'\n예정: '||to_char(j.due_at at time zone coalesce(prop.timezone,'Asia/Seoul'),'YYYY.MM.DD HH24:MI')
  ||E'\n'||case when p_kind='recovered' then '지연되었던 메시지가 발송되었습니다.' else '사유: '||coalesce(j.error,'발송 상태를 확인해주세요.') end
  ||E'\n'||case when p_kind='blocked' then '자동으로 다시 확인 중입니다. 직접 보내기 전 발송 기록을 확인해주세요.' when j.status='failed' then '자동메시지 발송 기록에서 사유와 예약정보를 확인해주세요. 문제 해결 후 이 실패 건의 재전송 버튼을 눌러주세요.' when j.status='uncertain' then '중복 발송을 막기 위해 자동 재발송하지 않습니다. 게스트 대화에서 발송 여부를 확인해주세요.' when p_kind='recovered' then '추가로 발송할 필요가 없습니다.' else 'Guest message에서 예약을 확인하고 필요한 안내를 직접 보내주세요.' end;
 insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
 values(prop.business_id,prop.id,'system',left(body,2000),'normal','general','auto_message',nid::text) returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_type,owner_id,recipient_key)
 select mid,'owner',o.id,'owner:'||o.id from public.owners o where omg_private.auto_message_owner_eligible(j.property_id,o.id);
 update omg_private.auto_message_notices set message_id=mid where id=nid;
end$function$
;

CREATE OR REPLACE FUNCTION omg_private.auto_message_scan()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 update omg_private.auto_message_deliveries set status='uncertain',error='발송 응답이 끊겨 성공 여부를 확인하지 못했습니다.',updated_at=now() where status='sending' and updated_at<now()-interval '3 minutes';
 update omg_private.auto_message_deliveries set status='failed',lease=null,leased_until=null,error='예약정보 확인 시간이 초과되어 발송하지 않았습니다. 연동 상태를 확인해주세요.',updated_at=now() where status='preparing' and leased_until<now();
 -- Refresh pending dates before aging jobs out, so a postponed check-in isn't expired.
 update omg_private.auto_message_deliveries d set due_at=omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul')),
  next_at=greatest(now(),omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul'))),revision=r.revision,title=r.title
 from omg_private.auto_message_rules r,omg_private.online_bookings b,public.properties p
 where d.rule_id=r.id and d.property_id=b.property_id and d.booking_id=b.id and p.id=d.property_id and d.status='waiting' and not d.manual_retry
  and omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul')) is not null
  and d.due_at is distinct from omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul'));
 update omg_private.auto_message_deliveries d set status=case when d.manual_retry then 'failed' else 'skipped' end,error='자동 발송 설정이 중지되었습니다.',updated_at=now()
 from omg_private.auto_message_rules r where r.id=d.rule_id and not r.enabled and d.status='waiting';
 update omg_private.auto_message_deliveries set status='skipped',error='24시간 동안 발송하지 못해 재시도 기한이 지났습니다.',updated_at=now() where status='waiting' and not manual_retry and due_at<now()-interval '24 hours';
 insert into omg_private.auto_message_deliveries(rule_id,property_id,booking_id,title,revision,due_at,status,error)
 select r.id,r.property_id,b.id,r.title,r.revision,coalesce(t.due,now()),
  case when reason.value is null or t.due is null then 'waiting' else 'skipped' end,reason.value
 from omg_private.auto_message_rules r join public.properties p on p.id=r.property_id join omg_private.online_bookings b on b.property_id=r.property_id
 cross join lateral(select omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul')) due)t
 cross join lateral(select case
  when t.due is null then '예약일 또는 체크인 날짜가 없어 발송 시점을 계산할 수 없습니다.'
  when r.trigger='checkin_before' and t.due<b.booked_at then '예약 접수 전에 예정된 발송 시점이 지났습니다. 당일·임박 예약 여부를 확인해주세요.'
  when t.due<r.enabled_from then '자동메시지 사용을 시작하기 전에 발송 시점이 지났습니다.'
  when t.due>=((b.departure+1)::timestamp at time zone coalesce(p.timezone,'Asia/Seoul')) then '발송 예정일이 체크아웃 이후여서 발송 대상에서 제외되었습니다.'
  when t.due<now()-interval '24 hours' then '동기화 또는 처리 지연으로 발송 가능 기간을 놓쳤습니다.' end value)reason
 where r.enabled and b.status in('new','confirmed') and (b.departure is null or b.departure>=(now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date or b.booked_at>=r.enabled_from)
  and (t.due<=now() or reason.value is not null)
  and not exists(select 1 from omg_private.auto_message_deliveries d where d.rule_id=r.id and d.booking_id=b.id)
 order by coalesce(t.due,now()) limit 300 on conflict(rule_id,booking_id) do nothing;
 update omg_private.auto_message_deliveries set error='자동 발송 처리가 5분 이상 지연되고 있습니다.',updated_at=now()
 where status='waiting' and error is null and due_at<now()-interval '5 minutes' and created_at<now()-interval '5 minutes';
end$function$
;

CREATE OR REPLACE FUNCTION omg_private.auto_message_internal(p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j omg_private.auto_message_deliveries%rowtype; r omg_private.auto_message_rules%rowtype; b omg_private.online_bookings%rowtype; due timestamptz; tz text; why text;begin
 if p_action='pushes' then return coalesce((select jsonb_agg(jsonb_build_object('id',id,'message_id',message_id)) from(select id,message_id from omg_private.auto_message_notices where pushed_at is null and message_id is not null order by created_at limit 20)x),'[]');end if;
 if p_action='pushed' then update omg_private.auto_message_notices set pushed_at=now() where id=(p_data->>'id')::uuid;return jsonb_build_object('ok',true);end if;
 if p_action='claim' then
  perform omg_private.auto_message_scan();
  select * into j from omg_private.auto_message_deliveries where status='waiting' and next_at<=now() order by next_at,created_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  update omg_private.auto_message_deliveries set status='preparing',lease=gen_random_uuid(),leased_until=now()+interval '90 seconds',attempts=attempts+1,updated_at=now() where id=j.id returning * into j;
  select * into r from omg_private.auto_message_rules where id=j.rule_id;
  return to_jsonb(j)||jsonb_build_object('rule',to_jsonb(r),'timezone',(select timezone from public.properties where id=j.property_id));
 end if;
 select * into j from omg_private.auto_message_deliveries where id=(p_data->>'id')::uuid for update;
 if not found or j.lease is distinct from (p_data->>'lease')::uuid then return jsonb_build_object('skip',true);end if;
 if p_action='prepare' then
  if j.status<>'preparing' or j.leased_until<now() then return jsonb_build_object('skip',true);end if;
  select * into r from omg_private.auto_message_rules where id=j.rule_id for update;
  select * into b from omg_private.online_bookings where property_id=j.property_id and id=j.booking_id;
  select coalesce(timezone,'Asia/Seoul') into tz from public.properties where id=j.property_id;
  due:=omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,tz);
  why:=case when not r.enabled then '자동 발송 설정이 중지되었습니다.' when b.status is null or b.status not in('new','confirmed') then '예약이 취소되었거나 발송 가능한 상태가 아닙니다.'
    when not j.manual_retry and r.trigger='checkin_before' and due<b.booked_at then '예약 변경으로 예정된 발송 시점이 예약 접수 이전이 되었습니다.'
    when not j.manual_retry and due<r.enabled_from then '예약 변경 또는 설정 변경으로 예정된 발송 시점이 지났습니다.'
    when not j.manual_retry and due>=((b.departure+1)::timestamp at time zone tz) then '발송 예정일이 체크아웃 이후입니다.' end;
  if why is not null then update omg_private.auto_message_deliveries set status=case when j.manual_retry then 'failed' else 'skipped' end,error=why,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);end if;
  if due is null and not j.manual_retry then update omg_private.auto_message_deliveries set status='waiting',error='예약일 또는 체크인 날짜를 확인하지 못했습니다.',next_at=now()+interval '5 minutes',lease=null,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);end if;
  if r.revision<>j.revision or (not j.manual_retry and (due>now() or due is distinct from j.due_at)) then
   update omg_private.auto_message_deliveries set status='waiting',revision=r.revision,title=r.title,due_at=case when j.manual_retry then j.due_at else due end,next_at=case when j.manual_retry then now() else greatest(now()+interval '1 minute',due) end,lease=null,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);
  end if;
  update omg_private.auto_message_deliveries set status='sending',language=p_data->>'language',updated_at=now() where id=j.id;return jsonb_build_object('ok',true);
 elsif p_action='finish' then
  if j.status='preparing' and p_data->>'status' in('waiting','skipped','failed') then
   update omg_private.auto_message_deliveries set status=case when p_data->>'status'='waiting' then 'failed' else p_data->>'status' end,next_at=now()+interval '5 minutes',lease=null,leased_until=null,error=left(p_data->>'error',200),updated_at=now() where id=j.id;
  elsif j.status='sending' and p_data->>'status' in('sent','failed','uncertain') then
   update omg_private.auto_message_deliveries set status=p_data->>'status',error=left(p_data->>'error',200),updated_at=now() where id=j.id;
  end if;
 else raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true);
end$function$
;
create or replace function omg_private.auto_message_notice_trigger() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='waiting' and nullif(new.error,'') is not null then perform omg_private.auto_message_notice(new.id,'blocked');
 elsif new.status in('failed','uncertain','skipped') and (new.status<>'skipped' or coalesce(new.error,'')<>'자동 발송 설정이 중지되었습니다.') then perform omg_private.auto_message_notice(new.id,'terminal');
 elsif new.status='sent' and exists(select 1 from omg_private.auto_message_notices where delivery_id=new.id and retry_count=new.retry_count and kind='blocked') then perform omg_private.auto_message_notice(new.id,'recovered');end if;
 return new;
end$$;
create or replace function omg_private.auto_message_notice_context(p_message uuid,p_property uuid) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('delivery_id',d.id,'retry_count',n.retry_count,'status',d.status,'can_retry',
 d.status='failed' and d.retry_count=n.retry_count and r.enabled)
 from omg_private.auto_message_notices n join omg_private.auto_message_deliveries d on d.id=n.delivery_id join omg_private.auto_message_rules r on r.id=d.rule_id
 where n.message_id=p_message and d.property_id=p_property and n.kind='terminal'
$$;
revoke all on function omg_private.auto_message_notice_context(uuid,uuid) from public,anon,authenticated;

do $migration$ declare f text; signature text; needle text:=$n$'message_id',m.id,'property_id',m.property_id,$n$;begin
 for signature in select unnest(array['public.list_property_messages(uuid)','public.list_notification_bot_messages(uuid,timestamptz,uuid)']) loop
  f:=pg_get_functiondef(signature::regprocedure);
  if strpos(f,needle)=0 then raise exception 'Missing authorized message metadata anchor in %',signature;end if;
  execute replace(f,needle,needle||$n$'auto_message',case when v_is_owner and m.source='auto_message' then omg_private.auto_message_notice_context(m.id,m.property_id) else null end,$n$);
 end loop;
end $migration$;
commit;

