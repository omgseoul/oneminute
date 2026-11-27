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
