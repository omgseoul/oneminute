-- Fix PL/pgSQL record/SQL alias ambiguity in the notice delivery list.
create or replace function public.platform_system_notices(p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare tid uuid;t omg_private.system_notice_templates%rowtype;prop uuid;n int:=0;value text;placeholder text;send_token text:=gen_random_uuid()::text;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='save' then
  if p_data->>'event_key' not in('first_login','storage_warning','storage_full','trial_expiring','trial_expired','subscription_expiring','subscription_expired','service_updated','manual') then raise exception '알림 이벤트를 확인해주세요.';end if;
  value:=p_data->>'body';
  foreach placeholder in array array['사업장명','체험기간','제공용량','사용용량','종료일','남은일수','요금제','문의처'] loop value:=replace(value,'{'||placeholder||'}','');end loop;
  if value ~ '\{[^{}]+\}' then raise exception '지원하지 않는 치환 문구입니다. 화면의 자동입력 항목을 사용해주세요.';end if;
  tid:=nullif(p_data->>'id','')::uuid;
  if tid is null then insert into omg_private.system_notice_templates(event_key,title,body,enabled) values(p_data->>'event_key',btrim(p_data->>'title'),btrim(p_data->>'body'),coalesce((p_data->>'enabled')::boolean,true)) returning id into tid;
  else update omg_private.system_notice_templates set event_key=p_data->>'event_key',title=btrim(p_data->>'title'),body=btrim(p_data->>'body'),enabled=coalesce((p_data->>'enabled')::boolean,true),updated_at=now() where id=tid;
  if not found then raise exception '공지를 찾을 수 없습니다.';end if;end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'system_template_saved',jsonb_build_object('id',tid,'event_key',p_data->>'event_key'));
 elsif p_action='send' then
  select * into t from omg_private.system_notice_templates where id=(p_data->>'id')::uuid and enabled;
  if not found then raise exception '활성 공지를 선택해주세요.';end if;
  if jsonb_array_length(p_data->'property_ids') not between 1 and 500 then raise exception '수신 사업장을 선택해주세요.';end if;
  for prop in select distinct value::uuid from jsonb_array_elements_text(p_data->'property_ids') loop
   if not exists(select 1 from public.properties where id=prop) then raise exception '수신 사업장을 확인해주세요.';end if;
   n:=n+omg_private.emit_system_notice(prop,t.event_key,'manual:'||send_token,t.id);
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'system_notice_sent',jsonb_build_object('template_id',t.id,'count',n,'property_ids',p_data->'property_ids'));
 elsif p_action='retry' then
  update omg_private.system_notice_deliveries set attempts=0,last_attempt_at=null where delivered_at is null and id=(p_data->>'id')::bigint;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'sent',n,'templates',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') from omg_private.system_notice_templates x),
 'deliveries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select d.id,d.event_key,d.created_at,d.attempts,d.delivered_at,d.message_id,p.name property_name,nt.title,
  case when d.delivered_at is not null then 'sent' when d.attempts>=10 then 'failed' else 'pending' end status,
  (select count(*) from public.property_message_recipients where message_id=d.message_id) recipient_count,
  (select count(*) from public.property_message_recipients where message_id=d.message_id and read_at is not null) read_count
  from omg_private.system_notice_deliveries d join public.properties p on p.id=d.property_id join omg_private.system_notice_templates nt on nt.id=d.template_id order by d.created_at desc limit 100)x));
end$$;
