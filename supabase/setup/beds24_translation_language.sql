-- Property-owned incoming translation language; preserve all current inbox/auth paths.
alter table omg_private.online_connections add column if not exists incoming_translation_language text not null default 'ko' check(incoming_translation_language in('ko','en','ja','zh-CN','zh-TW','es','fr','de','it','pt','ru','vi','th','id','ar','hi'));

do $patch$
declare definition text;needle text;begin
 definition:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 if strpos(definition,'''incoming_translation_language'',c.incoming_translation_language')=0 then
  needle:='''translation_connected'',c.translation_vault_id is not null';
  if strpos(definition,needle)=0 then raise exception '번역 설정 함수의 변경 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,'''incoming_translation_language'',c.incoming_translation_language,'||needle);
 end if;
 if strpos(definition,'p_action=''save_translation_language''')=0 then
  needle:=' elsif p_action=''save_settings'' then';
  if strpos(definition,needle)=0 then raise exception '번역 저장 함수의 변경 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,E' elsif p_action=''save_translation_language'' then\n  if coalesce(p_data->>''target'','''') not in(''ko'',''en'',''ja'',''zh-CN'',''zh-TW'',''es'',''fr'',''de'',''it'',''pt'',''ru'',''vi'',''th'',''id'',''ar'',''hi'') then raise exception ''기본 번역 언어를 확인해주세요.'';end if;\n  update omg_private.online_connections set incoming_translation_language=p_data->>''target'' where property_id=home;\n  return jsonb_build_object(''ok'',true,''incoming_translation_language'',p_data->>''target'');\n'||needle);
 end if;
 execute definition;

 definition:=pg_get_functiondef('public.translation_control(text,uuid,uuid,jsonb)'::regprocedure);
 if strpos(definition,'v_known_language text')=0 then
  definition:=replace(definition,'declare sid uuid;','declare v_known_language text;sid uuid;');
  needle:='v_body:=m.body;v_book:=m.booking_id;v_target:=''ko'';';
  if strpos(definition,needle)=0 then raise exception '수신 번역 언어의 변경 위치를 확인해주세요.';end if;
  definition:=replace(definition,needle,'v_body:=m.body;v_book:=m.booking_id;v_target:=coalesce(nullif(p_data->>''target'',''''),(select incoming_translation_language from omg_private.online_connections where property_id=p_property),''ko'');');
  needle:='  perform pg_advisory_xact_lock(hashtextextended(''translation:''||p_property,812));';
  if strpos(definition,needle)=0 then raise exception '번역 언어 확인 위치를 확인해주세요.';end if;
  -- Apply only to claim's first lock; finish retains the same settlement logic.
  definition:=overlay(definition placing E'  if v_dir=''incoming'' then\n   select tj.source_language into v_known_language from omg_private.translation_jobs tj where tj.property_id=p_property and tj.booking_id=v_book and tj.direction=''incoming'' and tj.body_hash=md5(v_body) and tj.body=v_body and tj.status=''done'' and tj.source_language is not null order by tj.updated_at desc limit 1;\n   if v_known_language is null and v_body ~ ''[가-힣]'' and v_body !~ ''[A-Za-zぁ-ヿ一-鿿]'' then v_known_language:=''ko'';end if;\n   if lower(v_known_language)=lower(v_target) or (split_part(lower(v_known_language),''-'',1)=lower(v_target) and lower(v_target) not like ''zh%'') or (lower(v_known_language) in(''zh'',''zh-cn'',''zh-hans'') and lower(v_target) in(''zh'',''zh-cn'',''zh-hans'')) then\n    return jsonb_build_object(''cached'',true,''same_language'',true,''text'',v_body,''source_language'',v_known_language,''target'',v_target);\n   end if;\n  end if;\n'||needle from strpos(definition,needle) for length(needle));
 end if;
 execute definition;
end $patch$;
