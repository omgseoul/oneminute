CREATE OR REPLACE FUNCTION omg_private.ai_owner(p_token uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;home uuid;rows jsonb;item jsonb;v_mode text;st time;et time;begin
 a:=omg_private.guest_actor(p_token);if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 if nullif(p_data->>'property_id','') is not null then
  home:=(p_data->>'property_id')::uuid;
  if not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) then
   raise exception '이 지점의 AI 설정을 관리할 권한이 없습니다.';
  end if;
 end if;
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
end$function$
;
