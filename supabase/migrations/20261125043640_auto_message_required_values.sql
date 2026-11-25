begin;
-- Required-value lookup/render failures are terminal; retain existing authorization and deduplication.
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
    when r.trigger='checkin_before' and due<b.booked_at then '예약 변경으로 예정된 발송 시점이 예약 접수 이전이 되었습니다.'
    when due<r.enabled_from then '예약 변경 또는 설정 변경으로 예정된 발송 시점이 지났습니다.'
    when due>=((b.departure+1)::timestamp at time zone tz) then '발송 예정일이 체크아웃 이후입니다.' end;
  if why is not null then update omg_private.auto_message_deliveries set status='skipped',error=why,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);end if;
  if due is null then update omg_private.auto_message_deliveries set status='waiting',error='예약일 또는 체크인 날짜를 확인하지 못했습니다.',next_at=now()+interval '5 minutes',lease=null,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);end if;
  if r.revision<>j.revision or due>now() or due is distinct from j.due_at then
   update omg_private.auto_message_deliveries set status='waiting',revision=r.revision,title=r.title,due_at=due,next_at=greatest(now()+interval '1 minute',due),lease=null,updated_at=now() where id=j.id;return jsonb_build_object('skip',true);
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

CREATE OR REPLACE FUNCTION omg_private.auto_message_notice(p_delivery uuid, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j omg_private.auto_message_deliveries%rowtype; b omg_private.online_bookings%rowtype; prop public.properties%rowtype;
 nid uuid; mid uuid; title text; body text; begin
 select * into j from omg_private.auto_message_deliveries where id=p_delivery;if not found then return;end if;
 insert into omg_private.auto_message_notices(delivery_id,kind) values(j.id,p_kind) on conflict(delivery_id,kind) do nothing returning id into nid;
 if not found then return;end if;
 select * into b from omg_private.online_bookings where property_id=j.property_id and id=j.booking_id;
 select * into prop from public.properties where id=j.property_id;
 title:=case when p_kind='recovered' then '자동메시지 발송 완료' when p_kind='blocked' then '자동메시지 발송 지연' when j.status='failed' then '자동메시지 발송실패' when j.status='uncertain' then '자동메시지 발송 확인' else '자동메시지 미발송' end;
 body:='['||title||']'||E'\n'||prop.name||' · 객실 '||coalesce(nullif(b.room_name,''),'미정')||E'\n예약 #'||j.booking_id||coalesce(' · 채널 예약번호 '||nullif(b.data->>'apiReference',''),'')
  ||E'\n게스트: '||coalesce(nullif(btrim(regexp_replace(b.guest_name,'[0-9０-９]','','g')),''),'이름 미등록')
  ||E'\n메시지: '||j.title||E'\n예정: '||to_char(j.due_at at time zone coalesce(prop.timezone,'Asia/Seoul'),'YYYY.MM.DD HH24:MI')
  ||E'\n'||case when p_kind='recovered' then '지연되었던 메시지가 발송되었습니다.' else '사유: '||coalesce(j.error,'발송 상태를 확인해주세요.') end
  ||E'\n'||case when p_kind='blocked' then '자동으로 다시 확인 중입니다. 직접 보내기 전 발송 기록을 확인해주세요.' when j.status='failed' then '자동메시지 발송 기록에서 사유와 예약정보를 확인해주세요. 자동 재발송하지 않으므로 필요한 안내는 확인 후 직접 보내주세요.' when j.status='uncertain' then '중복 발송을 막기 위해 자동 재발송하지 않습니다. 게스트 대화에서 발송 여부를 확인해주세요.' when p_kind='recovered' then '추가로 발송할 필요가 없습니다.' else 'Guest message에서 예약을 확인하고 필요한 안내를 직접 보내주세요.' end;
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
 where d.rule_id=r.id and d.property_id=b.property_id and d.booking_id=b.id and p.id=d.property_id and d.status='waiting'
  and omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul')) is not null
  and d.due_at is distinct from omg_private.auto_message_due(r.trigger,r.days,r.send_time,b.booked_at,b.arrival,coalesce(p.timezone,'Asia/Seoul'));
 update omg_private.auto_message_deliveries d set status='skipped',error='자동 발송 설정이 중지되었습니다.',updated_at=now()
 from omg_private.auto_message_rules r where r.id=d.rule_id and not r.enabled and d.status='waiting';
 update omg_private.auto_message_deliveries set status='skipped',error='24시간 동안 발송하지 못해 재시도 기한이 지났습니다.',updated_at=now() where status='waiting' and due_at<now()-interval '24 hours';
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
commit;

