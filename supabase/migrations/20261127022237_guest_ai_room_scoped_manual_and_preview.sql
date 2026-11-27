-- Preserve the five-column manual and select applicable rows before model inference.
create function omg_private.ai_room_key(room text) returns text language sql immutable set search_path='' as $$
 select regexp_replace(regexp_replace(upper(btrim(coalesce(room,''))),'^(ROOM|객실)[[:space:]]*','','i'),'[[:space:]]*(호실|호)$','','i')
$$;
create function omg_private.ai_manual_normalize(rows jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare r jsonb;result jsonb:='[]';scope text;begin
 if jsonb_typeof(rows) is distinct from 'array' or jsonb_array_length(rows)>200 or octet_length(rows::text)>60000 then raise exception 'DATA는 200행, 총 60KB까지 입력할 수 있습니다.';end if;
 for r in select * from jsonb_array_elements(rows) loop
  if length(btrim(coalesce(r->>'title',''))) not between 1 and 120 or length(coalesce(r->>'answer',''))>4000 or length(coalesce(r->>'number',''))>40 or length(coalesce(r->>'category',''))>80 or length(coalesce(r->>'rooms',''))>1000 then raise exception '제목·답변·객실번호의 길이를 확인해주세요.';end if;
  scope:=coalesce(nullif(btrim(r->>'rooms'),''),'전체');
  if scope<>'전체' and (not exists(select from regexp_split_to_table(scope,'[,，;、\n]+')t where btrim(t)<>'') or exists(select from regexp_split_to_table(scope,'[,，;、\n]+')t where omg_private.ai_room_key(t)='' or length(omg_private.ai_room_key(t))>40 or t='전체')) then raise exception '객실번호는 전체 또는 101,102,401처럼 입력해주세요.';end if;
  result:=result||jsonb_build_array(jsonb_build_object('number',btrim(coalesce(r->>'number','')),'category',btrim(coalesce(r->>'category','')),'title',btrim(r->>'title'),'rooms',scope,'answer',btrim(coalesce(r->>'answer',''))));
 end loop;
 if octet_length(result::text)>60000 then raise exception 'DATA 총 용량은 60KB 이내로 입력해주세요.';end if;
 return result;
end$$;
create function omg_private.ai_manual_data(rows jsonb,room text) returns jsonb language sql stable set search_path='' as $$
 with entries as(select n,v,coalesce(nullif(btrim(v->>'rooms'),''),'전체') scope,omg_private.ai_room_key(room) roomkey from jsonb_array_elements(rows) with ordinality x(v,n) where nullif(btrim(v->>'answer'),'') is not null),
 candidates as(select *,scope='전체' common,exists(select from regexp_split_to_table(scope,'[,，;、\n]+')t where omg_private.ai_room_key(t)=roomkey and roomkey<>'') matched from entries)
 select coalesce(jsonb_agg(jsonb_build_object('id',n::text,'number',v->>'number','category',v->>'category','title',v->>'title','rooms',scope,'answer',v->>'answer') order by n),'[]') from candidates c
 where (matched or common) and not (common and exists(select from candidates s where s.scope<>'전체' and lower(btrim(s.v->>'title'))=lower(btrim(c.v->>'title')) and (s.matched or c.roomkey='')))
$$;
create function omg_private.ai_manual_room_topics(rows jsonb) returns jsonb language sql immutable set search_path='' as $$
 select coalesce(jsonb_agg(distinct v->>'title'),'[]') from jsonb_array_elements(rows)v where coalesce(nullif(btrim(v->>'rooms'),''),'전체')<>'전체' and nullif(btrim(v->>'answer'),'') is not null
$$;
revoke all on function omg_private.ai_room_key(text),omg_private.ai_manual_normalize(jsonb),omg_private.ai_manual_data(jsonb,text),omg_private.ai_manual_room_topics(jsonb) from public,anon,authenticated;

do $migration$
declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.ai_owner(uuid,text,jsonb)'::regprocedure);
 anchor:='rows:=coalesce(p_data->''data'',''[]'');';
 if strpos(def,anchor)=0 then raise exception 'Missing manual save validation';end if;
 def:=replace(def,anchor,'rows:=omg_private.ai_manual_normalize(coalesce(p_data->''data'',''[]''));');
 anchor:=$n$data=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'answer',btrim(j->>'answer'))),'[]') from jsonb_array_elements(rows)j)$n$;
 if strpos(def,anchor)=0 then raise exception 'Missing manual save columns';end if;
 execute replace(def,anchor,'data=rows');
 def:=pg_get_functiondef('omg_private.ai_claim()'::regprocedure);
 anchor:=$n$select coalesce(jsonb_agg(jsonb_build_object('id',x.n::text,'title',x.v->>'title','answer',x.v->>'answer')),'[]') into dataset from jsonb_array_elements(s.data) with ordinality x(v,n) where btrim(coalesce(x.v->>'answer',''))<>'';$n$;
 if strpos(def,anchor)=0 then raise exception 'Missing QR manual selection';end if;
 def:=replace(def,anchor,'dataset:=omg_private.ai_manual_data(s.data,case when r.room_unknown then null else r.room_number end);');
 def:=replace(def,$n$'data',dataset,'history',history$n$,$n$'room_number',case when r.room_unknown then null else r.room_number end,'room_topics',omg_private.ai_manual_room_topics(s.data),'data',dataset,'history',history$n$);
 -- With only scoped rows and an unknown room, the model can ask for the room without guessing.
 def:=replace(def,$n$or dataset='[]'::jsonb$n$, $n$or (dataset='[]'::jsonb and omg_private.ai_manual_room_topics(s.data)='[]'::jsonb)$n$);
 def:=replace(def,'+16000)','+20000+octet_length(omg_private.ai_manual_room_topics(s.data)::text))');execute def;
 def:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);
 anchor:=$n$select coalesce(jsonb_agg(jsonb_build_object('id',n::text,'title',j->>'title','answer',j->>'answer')),'[]') into dataset from jsonb_array_elements(s.data) with ordinality t(j,n) where nullif(btrim(j->>'answer'),'') is not null;$n$;
 if strpos(def,anchor)=0 then raise exception 'Missing online manual selection';end if;
 def:=replace(def,anchor,'dataset:=omg_private.ai_manual_data(s.data,(select room_name from omg_private.online_bookings where property_id=p_property and id=bid));');
 def:=replace(def,$n$'data',dataset,'history',history$n$,$n$'room_number',(select room_name from omg_private.online_bookings where property_id=p_property and id=bid),'room_topics',omg_private.ai_manual_room_topics(s.data),'data',dataset,'history',history$n$);
 def:=replace(def,'+16000)','+20000+octet_length(omg_private.ai_manual_room_topics(s.data)::text))');execute def;
end$migration$;

-- Isolated, metered manual previews. No guest message, outbox or notification writes.
create table omg_private.ai_manual_tests(
 id uuid primary key,property_id uuid not null references public.properties(id) on delete cascade,
 status text not null default 'pending' check(status in('pending','completed','failed')),
 period date not null,reserved_micro bigint not null,charged_micro bigint not null default 0,
 attempted boolean not null default false,job jsonb not null,result jsonb,
 created_at timestamptz not null default now(),finished_at timestamptz);
alter table omg_private.ai_manual_tests enable row level security;
revoke all on omg_private.ai_manual_tests from public,anon,authenticated;
create index ai_manual_tests_property_created on omg_private.ai_manual_tests(property_id,created_at);
create function public.guest_ai_manual_test(p_token uuid default null,p_action text default 'status',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare a jsonb;prop uuid;j omg_private.ai_manual_tests;s omg_private.ai_settings;w omg_private.ai_wallets;rows jsonb;job jsonb;v_result jsonb;rid uuid;reserve bigint;cost bigint;it bigint;ot bigint;ct bigint;wt bigint;estimated boolean;begin
 if p_action in('prepare','status') then
  a:=omg_private.guest_actor(p_token);
  if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
  prop:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
  if not coalesce(omg_private.can_manage_shared_property(p_token,prop,'property_settings'),false) then raise exception '이 지점의 AI 설정을 관리할 권한이 없습니다.';end if;
 else
  select property_id into prop from omg_private.ai_manual_tests where id=(p_data->>'id')::uuid;
  if prop is null then raise exception '테스트를 찾을 수 없습니다.';end if;
 end if;
 perform omg_private.ai_refresh_month(prop);
 select * into w from omg_private.ai_wallets where property_id=prop for update;
 -- Recover interrupted previews conservatively. This also makes retries idempotent.
 for j in select * from omg_private.ai_manual_tests where property_id=prop and status='pending' and created_at<now()-interval '2 minutes' for update loop
  cost:=case when j.attempted then j.reserved_micro else 0 end;
  update omg_private.ai_usage_month set reserved_micro=greatest(0,reserved_micro-j.reserved_micro),used_micro=used_micro+cost,responses=responses+case when cost>0 then 1 else 0 end where property_id=prop and month=j.period;
  update omg_private.ai_manual_tests set status='failed',charged_micro=cost,result=jsonb_build_object('error','테스트 시간이 초과되었습니다. 다시 테스트해주세요.','estimated',j.attempted),finished_at=now() where id=j.id;
 end loop;
 rid:=(p_data->>'id')::uuid;
 if rid is null then raise exception '테스트 요청 번호가 필요합니다.';end if;
 select * into j from omg_private.ai_manual_tests where id=rid and property_id=prop for update;
 if p_action='prepare' and j.id is null then
  if exists(select from omg_private.ai_manual_tests where property_id=prop and created_at>now()-interval '10 seconds') then raise exception '잠시 후 다시 테스트해주세요.';end if;
  if exists(select from omg_private.ai_manual_tests where property_id=prop and status='pending') then raise exception '진행 중인 테스트가 있습니다. 완료 후 다시 시도해주세요.';end if;
  if not coalesce(w.enabled,false) or not exists(select from omg_private.ai_provider where enabled and vault_id is not null) then raise exception 'AI 서비스 연결과 사용 설정을 확인해주세요.';end if;
  if length(btrim(coalesce(p_data->>'question',''))) not between 1 and 2000 or length(coalesce(p_data->>'room_number',''))>40 or coalesce(p_data->>'room_number','') ~ '[,，;、\n]'  or length(btrim(coalesce(p_data->>'prompt',''))) not between 1 and 8000 then raise exception '질문은 1~2,000자, 객실번호는 40자 이내로 입력해주세요.';end if;
  rows:=omg_private.ai_manual_normalize(coalesce(p_data->'data','[]'));
  select * into s from omg_private.ai_settings where property_id=prop;
  job:=jsonb_build_object('room_number',nullif(omg_private.ai_room_key(p_data->>'room_number'),''),'room_topics',omg_private.ai_manual_room_topics(rows),'data',omg_private.ai_manual_data(rows,p_data->>'room_number'),'prompt',p_data->>'prompt','support_policy',s.support_policy,'history',jsonb_build_array(jsonb_build_object('role','user','content',btrim(p_data->>'question'))),'alert_rules',jsonb_build_object('handoff',omg_private.ai_validate_alert_config(coalesce(p_data->'handoff_config',s.handoff_config)),'emergency',omg_private.ai_validate_alert_config(coalesce(p_data->'emergency_config',s.emergency_config))));
  reserve:=ceil((octet_length(job::text)+20000)*0.125+2048*0.50)::bigint;
  insert into omg_private.ai_usage_month(property_id,month)values(prop,omg_private.ai_month()) on conflict do nothing;
  if w.monthly_limit_micro-coalesce((select used_micro+reserved_micro from omg_private.ai_usage_month where property_id=prop and month=omg_private.ai_month()),0)<reserve then raise exception 'AI 사용 가능 크레딧이 부족합니다.';end if;
  insert into omg_private.ai_manual_tests(id,property_id,period,reserved_micro,job) values(rid,prop,omg_private.ai_month(),reserve,job);
  update omg_private.ai_usage_month set reserved_micro=reserved_micro+reserve where property_id=prop and month=omg_private.ai_month();
  return jsonb_build_object('ok',true,'id',rid,'status','pending','start',true,'job',job);
 elsif j.id is null then raise exception '테스트를 찾을 수 없습니다.';
 elsif p_action='attempt' then
  if j.status<>'pending' or j.attempted then return jsonb_build_object('ok',true,'start',false);end if;
  update omg_private.ai_manual_tests set attempted=true where id=rid;
  return jsonb_build_object('ok',true,'start',true);
 elsif p_action='finish' and j.status='pending' then
  v_result:=coalesce(p_data->'result','{}');estimated:=coalesce((v_result->>'estimated')::boolean,false);
  it:=greatest(0,coalesce((v_result->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((v_result->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((v_result->>'cached_tokens')::bigint,0)));wt:=least(it-ct,greatest(0,coalesce((v_result->>'cache_write_tokens')::bigint,0)));
  cost:=least(j.reserved_micro,case when estimated then j.reserved_micro else ceil((it-ct-wt)*0.10+ct*0.01+wt*0.125+ot*0.50)::bigint end);
  update omg_private.ai_usage_month set reserved_micro=greatest(0,reserved_micro-j.reserved_micro),used_micro=used_micro+cost,responses=responses+case when cost>0 then 1 else 0 end,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=prop and month=j.period;
  update omg_private.ai_manual_tests set status=case when v_result ? 'error' then 'failed' else 'completed' end,result=v_result,charged_micro=cost,finished_at=now() where id=rid returning * into j;
 elsif p_action not in('prepare','status','finish') then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'id',j.id,'status',j.status,'result',j.result,'credits',j.charged_micro/1000.0,'usage',omg_private.ai_summary(prop));
end$$;
revoke all on function public.guest_ai_manual_test(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.guest_ai_manual_test(uuid,text,jsonb) to service_role;

create function omg_private.ai_manual_test_recover() returns void language plpgsql security definer set search_path='' as $$
declare t record;begin
 for t in select id from omg_private.ai_manual_tests where status='pending' and created_at<now()-interval '2 minutes' order by created_at limit 50 loop
  perform public.guest_ai_manual_test(null,'finish',jsonb_build_object('id',t.id));
 end loop;
 delete from omg_private.ai_manual_tests where finished_at<now()-interval '30 days';
end$$;
revoke all on function omg_private.ai_manual_test_recover() from public,anon,authenticated;
select cron.schedule('oms-ai-manual-test-recovery','*/5 * * * *','select omg_private.ai_manual_test_recover()');
