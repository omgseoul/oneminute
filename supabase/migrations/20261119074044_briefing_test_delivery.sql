-- A confirmed manual test uses the selected recipients immediately, without
-- changing the saved schedule or forcing the automatic briefing switch on.
do $migration$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 anchor:=$hook$  cfg:=omg_private.briefing_validate(data);per:=omg_private.briefing_period(prop,cfg);$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing preview hook';end if;
 definition:=replace(definition,anchor,$hook$  cfg:=omg_private.briefing_validate(data);
  if data ? 'notify_targets' then
   if jsonb_typeof(data->'notify_targets') is distinct from 'array' then
    raise exception '브리핑을 받을 근무자를 선택해주세요.';
   end if;
   if jsonb_array_length(data->'notify_targets') not between 1 and 1000 or exists(
    select 1 from jsonb_array_elements_text(data->'notify_targets') t(value)
    where value is null or (value not in ('all','reservation','onsite','cleaning') and not exists(
     select 1 from public.employees e where e.id::text=value and e.active and e.role<>'owner'
      and omg_private.briefing_can_receive(prop,e.property_id)
    ))
   ) then raise exception '브리핑을 받을 근무자를 선택해주세요.';end if;
   if not exists(
    select 1 from public.employees e where e.active and e.role<>'owner'
    and omg_private.briefing_can_receive(prop,e.property_id)
    and ((data->'notify_targets') ? e.id::text or (e.property_id=prop and
     ((data->'notify_targets') ? 'all' or (data->'notify_targets') ?| e.duty_roles)))
   ) then raise exception '선택한 역할에 해당하는 활성 근무자가 없습니다. 대상을 확인해주세요.';end if;
   cfg:=cfg||jsonb_build_object('notify_targets',data->'notify_targets');
  end if;
  per:=omg_private.briefing_period(prop,cfg);$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_enqueue_delivery(omg_private.briefing_runs)'::regprocedure);
 anchor:=$hook$case when run.settings->>'notify_kind'='time' then$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing delivery timing hook';end if;
 execute replace(definition,anchor,$hook$case when run.mode='manual' then now() when run.settings->>'notify_kind'='time' then$hook$);

 definition:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='s.property_id=r.property_id and s.enabled';
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing enabled check';end if;
 definition:=replace(definition,anchor,'s.property_id=r.property_id and (s.enabled or r.mode=''manual'')');
 definition:=replace(definition,'r.id run_id,r.summary','r.id run_id,r.mode,r.summary');
 execute replace(definition,$hook$'[메시지 브리핑] '||to_char$hook$,
  $hook$'[메시지 브리핑] '||case when delivery.mode='manual' then '[테스트] ' else '' end||to_char$hook$);

 definition:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 anchor:=$hook$ if items='[]'::jsonb then update omg_private.briefing_runs set status='empty',summary='해당 기간에 새로 수신한 게스트 대화가 없습니다.',finished_at=now() where id=r.id;return jsonb_build_object('skip',true);end if;$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing empty result hook';end if;
 definition:=replace(definition,anchor,$hook$ if items='[]'::jsonb then
  update omg_private.briefing_runs set status='empty',summary='해당 기간에 새로 수신한 게스트 대화가 없습니다.',finished_at=now() where id=r.id;
  if r.mode='manual' and r.settings ? 'notify_targets' then
   perform omg_private.briefing_enqueue_delivery(r);
  end if;
  return jsonb_build_object('skip',true);
 end if;$hook$);
 anchor:=$hook$  -- Manual test runs display a result in the settings only. Scheduled summaries
  -- go to the property's owners, shared-message owners and reservation staff.$hook$;
 if strpos(definition,anchor)=0 then raise exception 'Missing briefing completion hook';end if;
 execute replace(definition,anchor,$hook$  if err is null and r.mode='manual' and r.settings ? 'notify_targets' then
   perform omg_private.briefing_enqueue_delivery(r);
  end if;$hook$);
end
$migration$;
