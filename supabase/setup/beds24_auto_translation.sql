-- Opt-in incoming translation preferences and booking feed status filtering.
alter table omg_private.online_connections add column if not exists auto_translate boolean not null default false,add column if not exists translation_excluded_languages text[] not null default '{}';
create or replace function omg_private.translation_language(code text)returns text language sql immutable security invoker set search_path='' as $$
 select case when lower(replace(code,'_','-')) in('zh','zh-cn','zh-hans') then 'zh-cn' when lower(replace(code,'_','-')) in('zh-tw','zh-hant','zh-hk') then 'zh-tw' when lower(code)='iw' then 'he' when lower(code)='jw' then 'jv' when lower(code)='tl' then 'fil' else split_part(lower(replace(code,'_','-')),'-',1) end
$$;
revoke all on function omg_private.translation_language(text) from public,anon,authenticated;
grant execute on function omg_private.translation_language(text) to service_role;

create or replace function omg_private.online_translation_preferences(prop uuid,action text,d jsonb)returns jsonb language plpgsql security invoker set search_path='' as $$
declare codes text[];enabled boolean;m omg_private.online_messages%rowtype;lang text;target text;begin
 if action='save_auto_translation' then
  if jsonb_typeof(d->'enabled') is distinct from 'boolean' or jsonb_typeof(d->'excluded') is distinct from 'array' or jsonb_array_length(d->'excluded')>300 then raise exception '자동번역 설정을 확인해주세요.';end if;
  if exists(select 1 from jsonb_array_elements(d->'excluded') x where jsonb_typeof(x)<>'string' or trim(both '"' from x::text)!~'^[a-z]{2,3}(-[A-Za-z]{2,4})?$' or trim(both '"' from x::text) in('und','auto')) then raise exception '제외 언어를 확인해주세요.';end if;
  select coalesce(array_agg(distinct omg_private.translation_language(x) order by omg_private.translation_language(x)),'{}')into codes from jsonb_array_elements_text(d->'excluded')x;
  update omg_private.online_connections set auto_translate=(d->>'enabled')::boolean,translation_excluded_languages=codes where property_id=prop;
  return jsonb_build_object('ok',true,'auto_translate',(d->>'enabled')::boolean,'translation_excluded_languages',codes);
 end if;
 select c.auto_translate,c.translation_excluded_languages,c.incoming_translation_language into enabled,codes,target from omg_private.online_connections c where c.property_id=prop;
 if not coalesce(enabled,false) then return jsonb_build_object('skipped',true,'reason','disabled');end if;
 select * into m from omg_private.online_messages where property_id=prop and id=(d->>'message_id')::bigint and source='guest';
 if not found then raise exception '수신 메시지를 찾을 수 없습니다.';end if;
 select tj.source_language into lang from omg_private.translation_jobs tj where tj.property_id=prop and tj.booking_id=m.booking_id and tj.body_hash=md5(m.body) and tj.body=m.body and tj.direction='incoming' and tj.status='done' and tj.source_language is not null order by tj.updated_at desc limit 1;
 if lang is null and m.body ~ '[가-힣]' and m.body !~ '[A-Za-zぁ-ヿ一-鿿]' then lang:='ko';end if;
 if omg_private.translation_language(lang)=any(codes) then return jsonb_build_object('skipped',true,'reason','excluded','source_language',lang,'target',target);end if;
 return jsonb_build_object('target',target,'source_language',lang,'needs_detection',lang is null and cardinality(codes)>0);
end$$;
revoke all on function omg_private.online_translation_preferences(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function omg_private.online_translation_preferences(uuid,text,jsonb) to service_role;

do $patch$
declare f text;n text;begin
 f:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(f,'''auto_translate'',c.auto_translate')=0 then
  n:='''translation_connected'',c.translation_vault_id is not null';if strpos(f,n)=0 then raise exception '번역 설정 위치를 확인해주세요.';end if;
  f:=replace(f,n,'''auto_translate'',c.auto_translate,''translation_excluded_languages'',c.translation_excluded_languages,'||n);
  n:=' elsif p_action=''save_settings'' then';if strpos(f,n)=0 then raise exception '자동번역 저장 위치를 확인해주세요.';end if;
  f:=replace(f,n,E' elsif p_action=''save_auto_translation'' then\n  return omg_private.online_translation_preferences(home,p_action,p_data);\n'||n);
 end if;execute f;
 f:=pg_get_functiondef('public.translation_control(text,uuid,uuid,jsonb)'::regprocedure);
 if strpos(f,'online_translation_preferences(p_property,''auto_prepare''')=0 then
  n:=' elsif p_action=''claim'' then';if strpos(f,n)=0 then raise exception '자동번역 확인 위치를 확인해주세요.';end if;
  f:=replace(f,n,E' elsif p_action=''auto_prepare'' then\n  return omg_private.online_translation_preferences(p_property,''auto_prepare'',p_data);\n'||n);
  n:='  perform pg_advisory_xact_lock(hashtextextended(''translation:''||p_property,812));';
  f:=overlay(f placing E'  if v_dir=''incoming'' and coalesce((p_data->>''automatic'')::boolean,false) then\n   s:=omg_private.online_translation_preferences(p_property,''auto_prepare'',p_data);\n   if coalesce((s->>''skipped'')::boolean,false) then return s;end if;\n  end if;\n'||n from strpos(f,n) for length(n));
 end if;execute f;
 f:=pg_get_functiondef('omg_private.online_booking_data(uuid,text,jsonb,text)'::regprocedure);
 if strpos(f,'jsonb_array_elements_text(p_data->''statuses'')')=0 then
  n:='b.property_id=prop and b.booked_at >=';if strpos(f,n)=0 then raise exception '예약상태 필터 위치를 확인해주세요.';end if;
  f:=replace(f,n,'b.property_id=prop and (not(p_data ? ''statuses'') or coalesce(nullif(b.status,''''),''unknown'') in(select jsonb_array_elements_text(p_data->''statuses''))) and b.booked_at >=');
 end if;execute f;
end $patch$;
