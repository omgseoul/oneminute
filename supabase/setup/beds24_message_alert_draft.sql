-- Prepare online-message alert settings only. Do not alter notification recipients or delivery.
alter table omg_private.online_connections add column if not exists online_message_alert_draft jsonb;
create or replace function omg_private.save_online_message_alert_draft(prop uuid,d jsonb)returns jsonb language plpgsql security invoker set search_path='' as $$
declare cfg jsonb:=d->'config';kind text;r jsonb;result jsonb:='{}';scopes jsonb;begin
 if jsonb_typeof(cfg) is distinct from 'object' then raise exception '온라인 메시지 알림 설정을 확인해주세요.';end if;
 foreach kind in array array['staff','owner'] loop
  r:=cfg->kind;
  if jsonb_typeof(r) is distinct from 'object' or jsonb_typeof(r->'enabled') is distinct from 'boolean' or coalesce(r->>'mode','') not in('weak','normal','strong','urgent') or jsonb_typeof(r->'scopes') is distinct from 'array' then raise exception '대상과 알림 강도를 확인해주세요.';end if;
  if jsonb_array_length(r->'scopes')>4 or exists(select 1 from jsonb_array_elements(r->'scopes')x where jsonb_typeof(x)<>'string' or x#>>'{}' not in('all','checkin','staying','checkout')) then raise exception '수신할 게스트 대상을 확인해주세요.';end if;
  select coalesce(jsonb_agg(distinct x order by x),'[]') into scopes from jsonb_array_elements_text(r->'scopes')x;
  if scopes ? 'all' then scopes:='["all"]';end if;
  if (r->>'enabled')::boolean and jsonb_array_length(scopes)=0 then raise exception '수신할 메시지를 하나 이상 선택해주세요.';end if;
  r:=jsonb_build_object('enabled',(r->>'enabled')::boolean,'mode',r->>'mode','scopes',scopes);
  if kind='owner' then
   if jsonb_typeof(cfg->kind->'time_enabled') is distinct from 'boolean' or jsonb_typeof(cfg->kind->'no_staff_only') is distinct from 'boolean' or coalesce(cfg->kind->>'from','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(cfg->kind->>'to','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception '관리자 수신 시간을 확인해주세요.';end if;
   if (cfg->kind->>'time_enabled')::boolean and cfg->kind->>'from'=cfg->kind->>'to' then raise exception '수신 시작·종료 시간을 다르게 선택해주세요.';end if;
   r:=r||jsonb_build_object('time_enabled',(cfg->kind->>'time_enabled')::boolean,'from',cfg->kind->>'from','to',cfg->kind->>'to','no_staff_only',(cfg->kind->>'no_staff_only')::boolean);
  end if;
  result:=result||jsonb_build_object(kind,r);
 end loop;
 update omg_private.online_connections set online_message_alert_draft=result where property_id=prop;
 return jsonb_build_object('ok',true,'online_message_alert_draft',result,'pending',true);
end$$;
revoke all on function omg_private.save_online_message_alert_draft(uuid,jsonb) from public,anon,authenticated;
grant execute on function omg_private.save_online_message_alert_draft(uuid,jsonb) to service_role;
do $patch$
declare f text;n text;begin
 f:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,'''online_message_alert_draft'',c.online_message_alert_draft')=0 then
  n:='''translation_connected'',c.translation_vault_id is not null';if strpos(f,n)=0 then raise exception '기본정보 설정 위치를 확인해주세요.';end if;
  f:=replace(f,n,'''online_message_alert_draft'',c.online_message_alert_draft,'||n);
  n:=' elsif p_action=''save_settings'' then';if strpos(f,n)=0 then raise exception '알림 설정 저장 위치를 확인해주세요.';end if;
  f:=replace(f,n,E' elsif p_action=''save_message_alert_draft'' then\n  return omg_private.save_online_message_alert_draft(home,p_data);\n'||n);
 end if;execute f;
end $patch$;
