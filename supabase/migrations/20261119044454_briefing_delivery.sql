alter table omg_private.briefing_settings
 add column notify_kind text check(notify_kind in ('time','checkin')),
 add column notify_time time,
 add column notify_targets text[] not null default '{reservation}',
 add constraint briefing_notify_time_required check(notify_kind is distinct from 'time' or notify_time is not null);

create table omg_private.briefing_deliveries (
 id uuid primary key default gen_random_uuid(),
 run_id uuid not null references omg_private.briefing_runs(id) on delete cascade,
 employee_id uuid not null references public.employees(id) on delete cascade,
 due_at timestamptz,
 message_ids uuid[] not null default '{}',
 queued_at timestamptz,
 pushed_at timestamptz,
 unique(run_id,employee_id)
);
alter table omg_private.briefing_deliveries enable row level security;
revoke all on omg_private.briefing_deliveries from public,anon,authenticated;
create index briefing_delivery_pending on omg_private.briefing_deliveries(run_id) where pushed_at is null;

create function omg_private.briefing_enqueue_delivery(run omg_private.briefing_runs)
returns void language sql set search_path='' as $$
 insert into omg_private.briefing_deliveries(run_id,employee_id,due_at)
 select run.id,e.id,case when run.settings->>'notify_kind'='time' then
   (local_end::date + (run.settings->>'notify_time')::time
     + case when (run.settings->>'notify_time')::time<date_trunc('minute',local_end)::time then interval '1 day' else interval '0' end)
     at time zone run.timezone end
 from public.employees e
 cross join lateral (select run.period_end at time zone run.timezone as local_end) bounds
 where e.active and e.role<>'owner' and e.property_id=run.property_id
   and (run.settings->'notify_targets' ? 'all'
    or run.settings->'notify_targets' ? e.id::text
    or (run.settings->'notify_targets') ?| e.duty_roles)
 on conflict(run_id,employee_id) do nothing
$$;
revoke all on function omg_private.briefing_enqueue_delivery(omg_private.briefing_runs) from public,anon,authenticated;

create function omg_private.briefing_release_deliveries()
returns void language plpgsql set search_path='' as $$
declare
 delivery record;
 part integer;
 parts integer;
 message_id uuid;
 ids uuid[];
begin
 for delivery in
  select d.id,d.employee_id,r.id run_id,r.summary,r.property_id,r.period_start,r.period_end,r.timezone,p.business_id
  from omg_private.briefing_deliveries d
  join omg_private.briefing_runs r on r.id=d.run_id
  join omg_private.briefing_settings s on s.property_id=r.property_id and s.enabled
  join public.properties p on p.id=r.property_id
  join public.employees e on e.id=d.employee_id and e.property_id=r.property_id and e.active and e.role<>'owner'
  where d.queued_at is null and r.finished_at>now()-interval '7 days'
    and (d.due_at<=now() or (d.due_at is null and exists(
      select 1 from public.work_sessions w where w.employee_id=d.employee_id and w.property_id=r.property_id
       and w.checkin_report_at>=r.period_end and w.checkin_report_at<=now()
    )))
  order by r.finished_at,d.id limit 40 for update of d skip locked
 loop
  ids:='{}';
  parts:=ceil(char_length(delivery.summary)/1700.0);
  for part in 1..parts loop
   insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
   values(delivery.business_id,delivery.property_id,'system',
     '[메시지 브리핑] '||to_char(delivery.period_start at time zone delivery.timezone,'MM.DD HH24:MI')||' ~ '||
     to_char(delivery.period_end at time zone delivery.timezone,'MM.DD HH24:MI')||
     case when parts>1 then ' ('||part||'/'||parts||')' else '' end||E'\n'||
     substring(delivery.summary from (part-1)*1700+1 for 1700),
     'normal','general','bot_briefing',delivery.id::text||':'||part)
   returning id into message_id;
   insert into public.property_message_recipients(message_id,recipient_type,employee_id,recipient_key)
   values(message_id,'staff',delivery.employee_id,'employee:'||delivery.employee_id);
   ids:=array_append(ids,message_id);
  end loop;
  update omg_private.briefing_deliveries set queued_at=now(),message_ids=ids where id=delivery.id;
 end loop;
end$$;
revoke all on function omg_private.briefing_release_deliveries() from public,anon,authenticated;

-- Keep the deployed billing, run and authorization logic, modifying only the delivery hooks.
do $migration$
declare definition text; fragment text;
begin
 definition:=pg_get_functiondef('omg_private.briefing_owner(uuid,uuid,text,jsonb)'::regprocedure);
 fragment:=$hook$  cfg:=omg_private.briefing_validate(data);
  update omg_private.briefing_settings$hook$;
 if strpos(definition,fragment)=0 then raise exception 'Missing briefing settings hook';end if;
 definition:=replace(definition,fragment,$hook$  cfg:=omg_private.briefing_validate(data);
  if data ? 'notify_kind' then
   if coalesce(data->>'notify_kind','') not in ('time','checkin')
      or (data->>'notify_kind'='time' and coalesce(data->>'notify_time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')
      or jsonb_typeof(data->'notify_targets') is distinct from 'array' then
    raise exception '브리핑 대상과 알림 시점을 확인해주세요.';
   end if;
   if jsonb_array_length(data->'notify_targets') not between 1 and 1000 or exists(
    select 1 from jsonb_array_elements_text(data->'notify_targets') target(value)
    where value is null or (value not in ('all','reservation','onsite','cleaning') and not exists(
     select 1 from public.employees e where e.id::text=value and e.property_id=prop and e.active and e.role<>'owner'
    ))
   ) then raise exception '받을 근무자를 선택해주세요.';end if;
   update omg_private.briefing_settings set notify_kind=data->>'notify_kind',
    notify_time=case when data->>'notify_kind'='time' then (data->>'notify_time')::time end,
    notify_targets=array(select distinct value from jsonb_array_elements_text(data->'notify_targets') target(value))
   where property_id=prop;
  end if;
  update omg_private.briefing_settings$hook$);
 fragment:=$hook$'usage',omg_private.ai_summary(prop)$hook$;
 if strpos(definition,fragment)=0 then raise exception 'Missing briefing employee list hook';end if;
 definition:=replace(definition,fragment,$hook$'employees',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name) order by e.display_name,e.id),'[]') from public.employees e where e.property_id=prop and e.active and e.role<>'owner'),'usage',omg_private.ai_summary(prop)$hook$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.briefing_worker(text,jsonb)'::regprocedure);
 fragment:=$hook$   parts:=ceil(char_length(txt)/1700.0)::int;$hook$;
 if strpos(definition,fragment)=0 then raise exception 'Missing briefing enqueue hook';end if;
 definition:=replace(definition,fragment,$hook$   if r.settings->>'notify_kind' is not null then
    perform omg_private.briefing_enqueue_delivery(r);
    return jsonb_build_object('ok',true,'id',r.id);
   end if;
   parts:=ceil(char_length(txt)/1700.0)::int;$hook$);
 fragment:=$hook$ elsif action='pushes' then$hook$;
 if strpos(definition,fragment)=0 then raise exception 'Missing briefing push hook';end if;
 definition:=left(definition,strpos(definition,fragment)-1)||$hook$ elsif action='pushes' then
  perform omg_private.briefing_release_deliveries();
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'message_ids',message_ids)) from (
   select id,message_ids,finished_at as queued_at from omg_private.briefing_runs where push_sent_at is null and cardinality(message_ids)>0 and finished_at>now()-interval '1 day'
   union all
   select id,message_ids,queued_at from omg_private.briefing_deliveries where pushed_at is null and queued_at>now()-interval '1 day'
   order by queued_at limit 8
  ) batches),'[]');
 elsif action='pushed' then
  update omg_private.briefing_deliveries set pushed_at=now() where id=(data->>'id')::uuid and queued_at is not null;
  update omg_private.briefing_runs set push_sent_at=now() where id=(data->>'id')::uuid;
  return jsonb_build_object('ok',true);
 end if;
 raise exception '잘못된 작업입니다.';
end$function$
$hook$;
 -- pg_get_functiondef uses $function$ as the PL/pgSQL body tag.
 execute definition;
end
$migration$;
