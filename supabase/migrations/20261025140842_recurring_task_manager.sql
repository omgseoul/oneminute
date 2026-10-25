begin;
-- Recurrence definitions are private; clients use the session-scoped RPC only.
create table omg_private.recurring_tasks (
 id uuid primary key default gen_random_uuid(),
 property_id uuid not null references public.properties(id),
 source_property_id uuid not null references public.properties(id),
 managed_by uuid not null references public.owners(id),
 title text not null check(char_length(title) between 1 and 100),
 description text not null default '' check(char_length(description)<=2000),
 start_date date not null,
 run_time time not null default '09:00',
 repeat_unit text not null check(repeat_unit in('day','week','month')),
 repeat_every integer not null check(repeat_every between 1 and 365),
 target_mode text not null check(target_mode in('all','selected','working')),
 target_employee_ids jsonb not null default '[]' check(jsonb_typeof(target_employee_ids)='array'),
 photo_required boolean not null default false,
 enabled boolean not null default true,
 archived boolean not null default false,
 next_date date not null,
 next_attempt_at timestamptz not null default now(),
 last_error text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index recurring_tasks_property_idx on omg_private.recurring_tasks(property_id);
create index recurring_tasks_due_idx on omg_private.recurring_tasks(next_date) where enabled and not archived;
create index recurring_tasks_source_idx on omg_private.recurring_tasks(source_property_id);
create index recurring_tasks_owner_idx on omg_private.recurring_tasks(managed_by);
create table omg_private.recurring_task_runs (
 task_id uuid not null references omg_private.recurring_tasks(id),
 run_date date not null,
 mission_id uuid references public.missions(id) on delete set null,
 title text not null,
 status text not null check(status in('created','skipped')),
 reason text,
 created_at timestamptz not null default now(),
 primary key(task_id,run_date)
);
create index recurring_task_runs_mission_idx on omg_private.recurring_task_runs(mission_id);
alter table omg_private.recurring_tasks enable row level security;
alter table omg_private.recurring_task_runs enable row level security;
revoke all on omg_private.recurring_tasks,omg_private.recurring_task_runs from public,anon,authenticated;

-- Always calculate from the original start day: Jan 31 -> Feb 28 -> Mar 31.
create function omg_private.task_date_on_or_after(p_start date,p_unit text,p_every integer,p_from date)
returns date language plpgsql immutable set search_path='' as $$
declare n integer;d date;months integer;
begin
 if p_every is null or p_every<1 or p_unit not in('day','week','month') then raise exception 'Invalid recurrence';end if;
 if p_from<=p_start then return p_start;end if;
 if p_unit in('day','week') then
  n:=p_every*case when p_unit='week' then 7 else 1 end;
  return p_start+(((p_from-p_start+n-1)/n)*n);
 end if;
 months:=(extract(year from p_from)::int-extract(year from p_start)::int)*12+extract(month from p_from)::int-extract(month from p_start)::int;
 n:=greatest(0,months/p_every);
 d:=(p_start+make_interval(months=>n*p_every))::date;
 if d<p_from then d:=(p_start+make_interval(months=>(n+1)*p_every))::date;end if;
 return d;
end $$;
revoke all on function omg_private.task_date_on_or_after(date,text,integer,date) from public,anon,authenticated;

create function omg_private.generate_recurring_tasks(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path='' as $$
declare t record;day date;ids jsonb;mid uuid;reason text;n integer:=0;loops integer;
begin
 -- SKIP LOCKED + unique occurrence key protect overlapping cron executions.
 for t in select r.*,p.business_id,p.timezone from omg_private.recurring_tasks r
  join public.properties p on p.id=r.property_id
  where r.enabled and not r.archived and r.next_attempt_at<=p_now and r.next_date<=(p_now at time zone p.timezone)::date
   and exists(select 1 from public.owners o where o.id=r.managed_by and o.active)
   and (r.source_property_id=r.property_id or exists(select 1 from public.property_share_requests s
     where s.requester_property_id=r.source_property_id and s.target_property_id=r.property_id
      and s.status='approved' and 'missions'=any(s.requested_permissions)))
  order by r.next_date,r.id limit 200 for update of r skip locked
 loop
  begin
  day:=(p_now at time zone t.timezone)::date;loops:=0;
  while t.next_date<=day and loops<100 loop
   exit when ((t.next_date+t.run_time) at time zone t.timezone)>p_now;
   loops:=loops+1;reason:=null;mid:=null;
   if not exists(select 1 from omg_private.recurring_task_runs where task_id=t.id and run_date=t.next_date) then
    select coalesce(jsonb_agg(e.id order by e.id),'[]'::jsonb) into ids from public.employees e
    where e.property_id=t.property_id and e.active and e.role<>'owner'
     and (t.target_mode='all' or (t.target_mode='selected' and t.target_employee_ids ? e.id::text)
      or (t.target_mode='working' and exists(select 1 from public.work_sessions s where s.employee_id=e.id
       and s.property_id=t.property_id and s.status='working' and s.checkin_report_at is not null
       and s.clock_out_at is null and s.checkout_report_at is null)));
    if t.target_mode='working' and t.next_date<day then reason:='당일 근무자 미배정';
    elsif jsonb_array_length(ids)=0 then
     if t.next_date=day then exit;end if;
     reason:='활성 대상 근무자 없음';
    end if;
    if reason is null then
     insert into public.missions(business_id,property_id,title,description,timing,priority,target_employee_ids,
       photo_required,due_at,creator_type,completion_mode)
     values(t.business_id,t.property_id,t.title,t.description,'today','normal',ids,t.photo_required,
       ((t.next_date+time '23:59:59') at time zone t.timezone),'owner','all') returning id into mid;
     n:=n+1;
    end if;
    insert into omg_private.recurring_task_runs(task_id,run_date,mission_id,title,status,reason)
     values(t.id,t.next_date,mid,t.title,case when mid is null then 'skipped' else 'created' end,reason);
   end if;
   t.next_date:=omg_private.task_date_on_or_after(t.start_date,t.repeat_unit,t.repeat_every,t.next_date+1);
   update omg_private.recurring_tasks set next_date=t.next_date where id=t.id;
  end loop;
  update omg_private.recurring_tasks set last_error=null where id=t.id;
  exception when others then
   update omg_private.recurring_tasks set last_error=left(sqlerrm,300),next_attempt_at=p_now+interval '15 minutes' where id=t.id;
   raise warning 'Recurring task % deferred: %',t.id,sqlerrm;
  end;
 end loop;
 return n;
end $$;
revoke all on function omg_private.generate_recurring_tasks(timestamptz) from public,anon,authenticated;

create function public.recurring_task_manager(p_access_token uuid,p_action text default 'list',p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare own uuid;home uuid;prop uuid;tid uuid;r omg_private.recurring_tasks%rowtype;targets jsonb;today date;
 v_start date;v_time time;v_unit text;v_every integer;v_mode text;v_enabled boolean;
 props jsonb;workers jsonb;items jsonb;runs jsonb;date_from date;date_to date;
begin
 select s.owner_id,s.property_id into own,home from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if not found then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.');end if;
 if p_action='save' then
  prop:=(p_data->>'property_id')::uuid;tid:=nullif(p_data->>'id','')::uuid;
  if prop is null or not omg_private.can_manage_shared_property(p_access_token,prop,'missions') then raise exception '이 지점의 테스크를 관리할 권한이 없습니다.';end if;
  if tid is not null then
   select * into r from omg_private.recurring_tasks where id=tid and not archived for update;
   if not found or not omg_private.can_manage_shared_property(p_access_token,r.property_id,'missions') then raise exception '테스크를 찾을 수 없습니다.';end if;
   if r.property_id<>prop then raise exception '등록된 테스크의 지점은 변경할 수 없습니다. 새로 등록해주세요.';end if;
  else
   perform pg_advisory_xact_lock(hashtextextended(prop::text,47));
   if (select count(*) from omg_private.recurring_tasks where property_id=prop and not archived)>=500 then raise exception '지점당 테스크는 최대 500개입니다.';end if;
  end if;
  select (now() at time zone timezone)::date into today from public.properties where id=prop;
  v_start:=(p_data->>'start_date')::date;v_time:=(p_data->>'run_time')::time;
  v_unit:=p_data->>'repeat_unit';v_every:=(p_data->>'repeat_every')::integer;v_mode:=p_data->>'target_mode';
  v_enabled:=coalesce((p_data->>'enabled')::boolean,true);targets:=coalesce(p_data->'target_employee_ids','[]'::jsonb);
  if v_start is null or v_time is null or v_unit is null or v_unit not in('day','week','month') or v_every is null or v_every not between 1 and 365
   or v_mode is null or v_mode not in('all','selected','working') or char_length(btrim(coalesce(p_data->>'title',''))) not between 1 and 100
   or char_length(coalesce(p_data->>'description',''))>2000 then raise exception '제목, 실행일, 반복주기와 대상을 확인해주세요.';end if;
  if v_start>today+3650 or (v_start<today and (tid is null or v_start<>r.start_date)) then raise exception '시작일은 오늘부터 10년 이내로 선택해주세요.';end if;
  if jsonb_typeof(targets)<>'array' or jsonb_array_length(targets)>100 then raise exception '대상 근무자를 확인해주세요.';end if;
  if v_mode='selected' then
   if jsonb_array_length(targets)=0 or exists(select 1 from jsonb_array_elements_text(targets)x(id)
    where not exists(select 1 from public.employees e where e.id::text=x.id and e.property_id=prop and e.active and e.role<>'owner')) then raise exception '해당 지점의 근무자를 선택해주세요.';end if;
   select jsonb_agg(distinct x) into targets from jsonb_array_elements(targets)x;
  else targets:='[]';end if;
  if tid is null then
   insert into omg_private.recurring_tasks(property_id,source_property_id,managed_by,title,description,start_date,run_time,repeat_unit,repeat_every,target_mode,target_employee_ids,photo_required,enabled,next_date)
   values(prop,home,own,btrim(p_data->>'title'),coalesce(p_data->>'description',''),v_start,v_time,v_unit,v_every,v_mode,targets,coalesce((p_data->>'photo_required')::boolean,false),v_enabled,v_start) returning id into tid;
  else
   update omg_private.recurring_tasks set source_property_id=home,managed_by=own,title=btrim(p_data->>'title'),description=coalesce(p_data->>'description',''),
    start_date=v_start,run_time=v_time,repeat_unit=v_unit,repeat_every=v_every,target_mode=v_mode,target_employee_ids=targets,
    photo_required=coalesce((p_data->>'photo_required')::boolean,false),enabled=v_enabled,
    next_date=case when r.start_date=v_start and r.repeat_unit=v_unit and r.repeat_every=v_every and r.enabled=v_enabled then r.next_date
      else omg_private.task_date_on_or_after(v_start,v_unit,v_every,today) end,next_attempt_at=now(),last_error=null,updated_at=now() where id=tid;
  end if;
  return jsonb_build_object('ok',true,'task_id',tid);
 elsif p_action='archive' then
  tid:=(p_data->>'id')::uuid;
  update omg_private.recurring_tasks set archived=true,enabled=false,updated_at=now()
   where id=tid and not archived and omg_private.can_manage_shared_property(p_access_token,property_id,'missions');
  if not found then raise exception '테스크를 종료할 권한이 없습니다.';end if;
  return jsonb_build_object('ok',true);
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 date_from:=coalesce((p_data->>'from')::date,date_trunc('month',now())::date);
 date_to:=coalesce((p_data->>'to')::date,(date_from+interval '1 month')::date);
 if date_to<date_from or date_to-date_from>93 then raise exception '조회 기간을 확인해주세요.';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'timezone',p.timezone,'is_own',p.id=home) order by p.id<>home,p.name),'[]') into props
 from public.properties p where omg_private.can_manage_shared_property(p_access_token,p.id,'missions');
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name,'property_id',e.property_id) order by e.display_name),'[]') into workers
 from public.employees e where e.active and e.role<>'owner' and exists(select 1 from jsonb_array_elements(props)p where p->>'id'=e.property_id::text);
 select coalesce(jsonb_agg((to_jsonb(t)-'managed_by'-'source_property_id')||jsonb_build_object('property_name',p.name,'timezone',p.timezone) order by t.created_at desc),'[]') into items
 from omg_private.recurring_tasks t join public.properties p on p.id=t.property_id
 where not t.archived and exists(select 1 from jsonb_array_elements(props)x where x->>'id'=t.property_id::text);
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('property_id',t.property_id,'property_name',p.name)),'[]') into runs
 from omg_private.recurring_task_runs x join omg_private.recurring_tasks t on t.id=x.task_id join public.properties p on p.id=t.property_id
 where x.run_date>=date_from and x.run_date<date_to and exists(select 1 from jsonb_array_elements(props)y where y->>'id'=t.property_id::text);
 return jsonb_build_object('ok',true,'properties',props,'employees',workers,'tasks',items,'runs',runs);
exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or check_violation then
 return jsonb_build_object('ok',false,'message','입력한 날짜, 반복주기와 대상을 확인해주세요.');
 when raise_exception then return jsonb_build_object('ok',false,'message',sqlerrm);
end $$;
revoke all on function public.recurring_task_manager(uuid,text,jsonb) from public;
grant execute on function public.recurring_task_manager(uuid,text,jsonb) to anon,authenticated;
select cron.schedule('oms-recurring-tasks','* * * * *','select omg_private.generate_recurring_tasks();');
commit;
