-- Property calendar entries are accessed only through session-checked RPCs.
create table public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  creator_kind text not null check (creator_kind in ('owner','staff')),
  creator_employee_id uuid references public.employees(id) on delete set null,
  owner_target boolean not null default false,
  target_employee_ids uuid[] not null default '{}',
  title text not null check (char_length(title) between 1 and 120),
  details text not null default '' check (char_length(details) <= 2000),
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint calendar_events_time_check check (end_at > start_at)
);
create index calendar_events_property_time_idx on public.calendar_events(property_id,start_at,end_at);
alter table public.calendar_events enable row level security;
revoke all on public.calendar_events from public, anon, authenticated;

create or replace function public.calendar_event_action(p_access_token uuid,p_action text,p_event jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  v_property_id uuid;
  v_employee_id uuid;
  v_owner boolean:=false;
  v_start timestamptz;
  v_end timestamptz;
  v_title text;
  v_details text;
  v_targets uuid[];
  v_owner_target boolean;
  v_id uuid;
  v_existing public.calendar_events%rowtype;
  v_events jsonb;
  v_tasks jsonb;
  v_employees jsonb;
begin
  select s.property_id into v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    v_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in ('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'message','로그인이 만료되었습니다. 다시 로그인해주세요.');
    end if;
  end if;

  if p_action='list' then
    v_start:=(p_event->>'range_start')::timestamptz;
    v_end:=(p_event->>'range_end')::timestamptz;
    if v_start is null or v_end is null or v_end<=v_start or v_end-v_start>interval '62 days' then
      return jsonb_build_object('ok',false,'message','조회 기간을 확인해주세요.');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'title',c.title,'details',c.details,'start_at',c.start_at,'end_at',c.end_at,
      'all_day',c.all_day,'owner_target',c.owner_target,
      'target_employee_ids',c.target_employee_ids,'creator_kind',c.creator_kind,
      'can_edit',v_owner or (c.creator_kind='staff' and c.creator_employee_id=v_employee_id),
      'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name)
        from public.employees e where e.id=any(c.target_employee_ids)),'[]'::jsonb)
    ) order by c.start_at,c.created_at),'[]'::jsonb) into v_events
    from public.calendar_events c
    where c.property_id=v_property_id and c.start_at<v_end and c.end_at>v_start
      and (v_owner or c.creator_employee_id=v_employee_id or v_employee_id=any(c.target_employee_ids));

    select coalesce(jsonb_agg(jsonb_build_object(
      'id',m.id,'title',m.title,'due_at',m.due_at,'target_employee_ids',m.target_employee_ids
    ) order by m.due_at,m.created_at),'[]'::jsonb) into v_tasks
    from public.missions m
    where m.property_id=v_property_id and m.active and m.creator_type='owner'
      and m.due_at>=v_start and m.due_at<v_end
      and (v_owner or m.target_employee_ids='[]'::jsonb or m.target_employee_ids ? v_employee_id::text);
    if v_owner then
      select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.display_name)
        order by e.display_name,e.id),'[]'::jsonb) into v_employees
      from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
    else v_employees:='[]'::jsonb;
    end if;
    return jsonb_build_object('ok',true,'events',v_events,'tasks',v_tasks,'employees',v_employees,'is_owner',v_owner);
  end if;

  if p_action='save' then
    v_title:=btrim(coalesce(p_event->>'title',''));
    v_details:=coalesce(p_event->>'details','');
    v_start:=(p_event->>'start_at')::timestamptz;
    v_end:=(p_event->>'end_at')::timestamptz;
    if char_length(v_title) not between 1 and 120 or char_length(v_details)>2000
      or v_start is null or v_end is null or v_end<=v_start or v_end-v_start>interval '7 days' then
      return jsonb_build_object('ok',false,'message','일정 제목과 시간을 확인해주세요.');
    end if;
    if v_owner then
      v_owner_target:=coalesce((p_event->>'owner_target')::boolean,false);
      select coalesce(array_agg(distinct x2.id),'{}'::uuid[]) into v_targets
      from jsonb_array_elements_text(coalesce(p_event->'target_employee_ids','[]'::jsonb)) as x(value)
      cross join lateral (select x.value::uuid as id) x2
      where x2.id is not null;
      if exists(select 1 from unnest(v_targets) t(id) where not exists(
        select 1 from public.employees e where e.id=t.id and e.property_id=v_property_id and e.active and e.role<>'owner'
      )) then return jsonb_build_object('ok',false,'message','선택한 직원 정보를 확인해주세요.'); end if;
      if not v_owner_target and cardinality(v_targets)=0 then
        return jsonb_build_object('ok',false,'message','일정 대상을 한 명 이상 선택해주세요.');
      end if;
    else
      v_owner_target:=false;
      v_targets:=array[v_employee_id];
    end if;
    if nullif(p_event->>'id','') is not null then
      v_id:=(p_event->>'id')::uuid;
      select * into v_existing from public.calendar_events c where c.id=v_id and c.property_id=v_property_id for update;
      if not found then return jsonb_build_object('ok',false,'message','일정을 찾지 못했습니다.'); end if;
      if not v_owner and (v_existing.creator_kind<>'staff' or v_existing.creator_employee_id is distinct from v_employee_id) then
        return jsonb_build_object('ok',false,'message','수정 권한이 없습니다.');
      end if;
      update public.calendar_events set title=v_title,details=v_details,start_at=v_start,end_at=v_end,
        all_day=coalesce((p_event->>'all_day')::boolean,false),
        owner_target=v_owner_target,target_employee_ids=v_targets,updated_at=clock_timestamp()
      where id=v_id;
    else
      insert into public.calendar_events(property_id,creator_kind,creator_employee_id,owner_target,
        target_employee_ids,title,details,start_at,end_at,all_day)
      values(v_property_id,case when v_owner then 'owner' else 'staff' end,
        case when v_owner then null else v_employee_id end,v_owner_target,v_targets,
        v_title,v_details,v_start,v_end,coalesce((p_event->>'all_day')::boolean,false))
      returning id into v_id;
    end if;
    return jsonb_build_object('ok',true,'id',v_id);
  end if;

  if p_action='delete' then
    v_id:=(p_event->>'id')::uuid;
    select * into v_existing from public.calendar_events c where c.id=v_id and c.property_id=v_property_id for update;
    if not found then return jsonb_build_object('ok',false,'message','일정을 찾지 못했습니다.'); end if;
    if not v_owner and (v_existing.creator_kind<>'staff' or v_existing.creator_employee_id is distinct from v_employee_id) then
      return jsonb_build_object('ok',false,'message','삭제 권한이 없습니다.');
    end if;
    delete from public.calendar_events where id=v_id;
    return jsonb_build_object('ok',true);
  end if;
  return jsonb_build_object('ok',false,'message','잘못된 요청입니다.');
end;
$function$;
revoke all on function public.calendar_event_action(uuid,text,jsonb) from public;
grant execute on function public.calendar_event_action(uuid,text,jsonb) to anon,authenticated;
