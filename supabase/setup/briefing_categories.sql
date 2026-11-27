alter table omg_private.briefing_settings add column categories jsonb;
alter table omg_private.briefing_deliveries add column categories text[];
-- Preserve explicitly selected people, while defaulting role-based delivery to their own work.
update omg_private.briefing_settings s set categories=(select jsonb_object_agg(k,jsonb_build_object('enabled',true,'targets',
 to_jsonb(array['manager',case when k='checkin' then 'reservation' else k end])||
 to_jsonb(array(select t from unnest(s.notify_targets)t where t ~ '^[0-9a-f-]{36}$'))||
 coalesce((select jsonb_agg('owner:'||o.id) from public.owners o where o.active and o.property_id<>s.property_id and omg_private.briefing_can_receive(s.property_id,o.property_id) and not ('skip-owner:'||o.id=any(s.notify_targets))),'[]')))
 from unnest(array['reservation','onsite','cleaning','checkin'])k);
alter table omg_private.briefing_settings alter column categories set default '{"reservation":{"enabled":true,"targets":["manager","reservation"]},"onsite":{"enabled":true,"targets":["manager","onsite"]},"cleaning":{"enabled":true,"targets":["manager","cleaning"]},"checkin":{"enabled":true,"targets":["manager","reservation"]}}';
alter table omg_private.briefing_settings alter column categories set not null;

create function omg_private.briefing_validate_categories(prop uuid,cfg jsonb) returns jsonb language plpgsql set search_path='' as $$
declare k text;c jsonb;t text;begin
 if jsonb_typeof(cfg) is distinct from 'object' or (select count(*) from jsonb_object_keys(cfg))<>4 then raise exception '브리핑 카테고리를 확인해주세요.';end if;
 for k,c in select * from jsonb_each(cfg) loop
  if k not in('reservation','onsite','cleaning','checkin') or jsonb_typeof(c->'enabled') is distinct from 'boolean' or jsonb_typeof(c->'targets') is distinct from 'array' then raise exception '브리핑 카테고리를 확인해주세요.';end if;
  if jsonb_array_length(c->'targets')>1000 then raise exception '브리핑 대상이 너무 많습니다.';end if;
  for t in select jsonb_array_elements_text(c->'targets') loop
   if t is null or not (t in('manager','reservation','onsite','cleaning','all') or exists(select from public.employees e where e.id::text=t and e.active and e.role<>'owner' and omg_private.briefing_can_receive(prop,e.property_id)) or exists(select from public.owners o where 'owner:'||o.id=t and o.active and omg_private.briefing_can_receive(prop,o.property_id))) then raise exception '권한이 없는 브리핑 수신 대상입니다.';end if;
  end loop;
 end loop;
 return cfg;
end$$;
create function omg_private.briefing_recipient_categories(prop uuid,cfg jsonb,employee uuid,owner uuid) returns text[] language sql stable set search_path='' as $$
 select coalesce(array_agg(k order by array_position(array['reservation','onsite','cleaning','checkin'],k)),'{}')
 from jsonb_each(cfg) x(k,c) where coalesce((c->>'enabled')::boolean,false) and (
 exists(select from public.employees e where e.id=employee and e.active and e.role<>'owner' and omg_private.briefing_can_receive(prop,e.property_id)
  and ((c->'targets') ? e.id::text or (e.property_id=prop and ((c->'targets') ? 'all' or (c->'targets') ?| e.duty_roles))))
 or exists(select from public.owners o where o.id=owner and o.active and omg_private.briefing_can_receive(prop,o.property_id)
  and ((o.property_id=prop and (c->'targets') ? 'manager') or (c->'targets') ? ('owner:'||o.id))))
$$;
create function omg_private.briefing_render(prop uuid,issues jsonb,categories text[],day date,error text default null) returns text language plpgsql stable set search_path='' as $$
declare k text;txt text:='';section text;row record;s jsonb;begin
 foreach k in array categories loop
  section:='';
  if k='checkin' then
   for row in select b.* from omg_private.online_bookings b where b.property_id=prop and b.arrival=day and b.status in('new','confirmed') order by b.room_name,b.guest_name,b.id loop
    s:=omg_private.pin_delivery_state(prop,row.id);
    section:=section||case when section<>'' then E'\n' else '' end||coalesce(row.room_name,'객실 미정')||' · '||coalesce(row.guest_name,'이름 미등록')||' · '||coalesce(row.arrival::text,'미정')||'~'||coalesce(row.departure::text,'미정')||' · '||coalesce(row.channel,'사이트 미확인')||' · 비번 '||
     case s->>'configured' when 'true' then '설정' when 'false' then '미설정' else '확인 필요' end||case when coalesce((s->>'active')::boolean,false) then ' / '||
     case s->>'state' when 'sent' then '발송 완료' when 'scheduled' then '발송 예정' when 'unsent' then '미발송' when 'failed' then '발송 실패' when 'resend' then '재발송 필요' when 'excluded' then '발송 제외' else '발송 확인 필요' end else '' end;
   end loop;
   if section='' then section:='오늘 체크인 예정 게스트 없음';end if;
  else
   for row in select i from jsonb_array_elements(coalesce(issues,'[]'))i where i->>'category'=k loop
    section:=section||case when section<>'' then E'\n\n' else '' end||'['||case row.i->>'urgency' when 'emergency' then '긴급·안전' when 'urgent' then '긴급' else '확인 필요' end||'] '||coalesce(row.i->>'room_number','객실 미확인')||' · '||coalesce(nullif(row.i->>'guest_name',''),'게스트')||E'\n'||coalesce(row.i->>'issue','')||E'\n상태: '||case row.i->>'status' when 'resolved' then '해결 완료' when 'needs_check' then '확인 필요' else '미해결' end||coalesce(' · '||nullif(row.i->>'action',''),'');
   end loop;
   if section='' then section:=case when error is not null then '대화 분석 실패 · 실행 로그를 확인해주세요.' else '보고할 사항 없음' end;end if;
  end if;
  txt:=txt||case when txt<>'' then E'\n\n' else '' end||'■ '||case k when 'reservation' then '예약관리' when 'onsite' then '현장관리' when 'cleaning' then '청소' else '체크인 명단 · '||day::text end||E'\n'||section;
 end loop;
 return txt;
end$$;

create or replace function omg_private.briefing_enqueue_delivery(run omg_private.briefing_runs) returns void language plpgsql set search_path='' as $$
declare cfg jsonb;local_end timestamp;due timestamptz;begin
 cfg:=coalesce(run.settings->'categories',(select categories from omg_private.briefing_settings where property_id=run.property_id));
 local_end:=run.period_end at time zone run.timezone;
 due:=case when run.mode='manual' then now() when run.settings->>'notify_kind'='time' then
 (local_end::date+(run.settings->>'notify_time')::time+case when (run.settings->>'notify_time')::time<date_trunc('minute',local_end)::time then interval '1 day' else interval '0' end) at time zone run.timezone end;
 insert into omg_private.briefing_deliveries(run_id,employee_id,due_at,categories)
 select run.id,e.id,due,omg_private.briefing_recipient_categories(run.property_id,cfg,e.id,null)
 from public.employees e where e.active and e.role<>'owner' and cardinality(omg_private.briefing_recipient_categories(run.property_id,cfg,e.id,null))>0 on conflict(run_id,employee_id) do nothing;
 insert into omg_private.briefing_deliveries(run_id,owner_id,due_at,categories)
 select run.id,o.id,coalesce(due,now()),omg_private.briefing_recipient_categories(run.property_id,cfg,null,o.id)
 from public.owners o where o.active and cardinality(omg_private.briefing_recipient_categories(run.property_id,cfg,null,o.id))>0 on conflict(run_id,owner_id) do nothing;
end$$;
revoke all on function omg_private.briefing_validate_categories(uuid,jsonb),omg_private.briefing_recipient_categories(uuid,jsonb,uuid,uuid),omg_private.briefing_render(uuid,jsonb,text[],date,text) from public,anon,authenticated;

do $migration$
declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 anchor:='  cfg:=omg_private.briefing_validate(data);';
 if strpos(def,anchor)=0 then raise exception 'Missing briefing validation hook';end if;
 def:=replace(def,anchor,anchor||$hook$
  cfg:=cfg||jsonb_build_object('categories',omg_private.briefing_validate_categories(prop,coalesce(data->'categories',(select categories from omg_private.briefing_settings where property_id=prop))));
  if action='save' then update omg_private.briefing_settings set categories=cfg->'categories' where property_id=prop;end if;
 $hook$);execute def;
 def:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 anchor:='  if items=''[]''::jsonb then';
 if strpos(def,anchor)=0 then raise exception 'Missing briefing empty hook';end if;
 def:=replace(def,anchor,$hook$  if items='[]'::jsonb or not exists(select from jsonb_each(r.settings->'categories')x where x.key<>'checkin' and (x.value->>'enabled')::boolean) and r.settings ? 'categories' then$hook$);
 anchor:=$hook$  if r.mode='manual' and r.settings ? 'notify_targets' then
   perform omg_private.briefing_enqueue_delivery(r);
  end if;$hook$;
 if strpos(def,anchor)=0 then raise exception 'Missing empty delivery hook';end if;
 def:=replace(def,anchor,$hook$
  update omg_private.briefing_runs set summary=omg_private.briefing_render(r.property_id,'[]',array(select key from jsonb_each(r.settings->'categories') where (value->>'enabled')::boolean),(now() at time zone r.timezone)::date) where id=r.id;
  perform omg_private.briefing_enqueue_delivery(r);
 $hook$);
 anchor:=$hook$  if err is null and r.mode='manual' and r.settings ? 'notify_targets' then$hook$;
 if strpos(def,anchor)=0 then raise exception 'Missing final delivery hook';end if;
 def:=replace(def,anchor,$hook$
  if r.settings ? 'categories' then
   update omg_private.briefing_runs set summary=omg_private.briefing_render(r.property_id,coalesce(data->'issues','[]'),array(select key from jsonb_each(r.settings->'categories') where (value->>'enabled')::boolean),(now() at time zone r.timezone)::date,err) where id=r.id returning * into r;
   perform omg_private.briefing_enqueue_delivery(r);
   return jsonb_build_object('ok',true,'id',r.id);
  end if;
 $hook$||anchor);execute def;
 def:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 anchor:='finished_at=now() where id=r.id;return jsonb_build_object(''skip'',true);';
 def:=replace(def,anchor,'finished_at=now() where id=r.id; if r.settings ? ''categories'' and coalesce((r.settings->''categories''->''checkin''->>''enabled'')::boolean,false) then perform omg_private.briefing_enqueue_delivery(r);end if;return jsonb_build_object(''skip'',true);');
 execute def;
 def:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='r.mode,r.summary,r.property_id';
 if strpos(def,anchor)=0 then raise exception 'Missing recipient summary hook';end if;
 def:=replace(def,anchor,$hook$r.mode,case when d.categories is null then r.summary else omg_private.briefing_render(r.property_id,r.issues,array(select k from unnest(d.categories)k where k=any(omg_private.briefing_recipient_categories(r.property_id,case when r.mode='manual' then r.settings->'categories' else s.categories end,d.employee_id,d.owner_id))),(now() at time zone r.timezone)::date,r.error) end as summary,r.property_id$hook$);
 execute def;
end$migration$;
