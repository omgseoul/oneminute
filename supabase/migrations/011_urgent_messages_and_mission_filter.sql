-- Web urgent-message inbox and employee mission filtering.
begin;

create table if not exists public.urgent_messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  employee_id uuid not null,
  message text not null check (char_length(btrim(message)) between 1 and 2000),
  created_at timestamptz not null default clock_timestamp(),
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.owners(id),
  foreign key (business_id,property_id,employee_id)
    references public.employees(business_id,property_id,id)
);

create index if not exists urgent_messages_property_created_idx
  on public.urgent_messages(property_id,created_at desc);

alter table public.urgent_messages enable row level security;
revoke all on table public.urgent_messages from public,anon,authenticated;

create or replace function public.send_urgent_message(p_access_token uuid,p_message text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_id uuid;v_text text:=btrim(coalesce(p_message,''));
begin
  if char_length(v_text) not between 1 and 2000 then
    return jsonb_build_object('ok',false,'code','invalid_message','message','긴급보고 내용을 입력해주세요.');
  end if;
  select s.* into v_session from public.work_sessions s
  join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and e.active
    and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 긴급보고를 보낼 수 있습니다.'); end if;
  insert into public.urgent_messages(business_id,property_id,employee_id,message)
  values(v_session.business_id,v_session.property_id,v_session.employee_id,v_text)
  returning id into v_id;
  return jsonb_build_object('ok',true,'message_id',v_id,'sent_at',clock_timestamp());
end;
$$;

create or replace function public.list_urgent_messages(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_items jsonb;v_unread integer;
begin
  select s.property_id into v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 받은 메시지를 확인할 수 있습니다.'); end if;
  select count(*)::integer into v_unread from public.urgent_messages
  where property_id=v_property_id and acknowledged_at is null;
  select coalesce(jsonb_agg(jsonb_build_object(
    'message_id',m.id,'employee_id',m.employee_id,'employee_name',e.display_name,
    'message',m.message,'created_at',m.created_at,'acknowledged_at',m.acknowledged_at
  ) order by m.created_at desc),'[]'::jsonb) into v_items
  from (select * from public.urgent_messages where property_id=v_property_id order by created_at desc limit 100)m
  join public.employees e on e.id=m.employee_id;
  return jsonb_build_object('ok',true,'messages',v_items,'unread_count',v_unread);
end;
$$;

create or replace function public.acknowledge_urgent_message(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_owner_id uuid;
begin
  select s.property_id,s.owner_id into v_property_id,v_owner_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 메시지를 확인 처리할 수 있습니다.'); end if;
  update public.urgent_messages set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),acknowledged_by=coalesce(acknowledged_by,v_owner_id)
  where id=p_message_id and property_id=v_property_id;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메시지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.list_missions(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb;v_employees jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.property_id,s.employee_id into v_property_id,v_employee_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name) order by e.created_at,e.id),'[]'::jsonb)
  into v_employees from public.employees e where e.property_id=v_property_id and e.active and e.role<>'owner';
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'title',m.title,'description',m.description,'timing',m.timing,'priority',m.priority,
    'target_employee_ids',m.target_employee_ids,'target_names',coalesce((select jsonb_agg(e.display_name order by e.display_name) from public.employees e where m.target_employee_ids ? e.id::text),'[]'::jsonb),
    'photo_required',m.photo_required,'estimated_minutes',m.estimated_minutes,'due_at',m.due_at,'created_at',m.created_at,
    'completed_at',c.completed_at,'completion_note',c.note,'completion_photo',case when v_is_owner then '' else coalesce(c.photo_data_url,'') end,
    'completion_employee_ids',coalesce((select jsonb_agg(mc.employee_id) from public.mission_completions mc where mc.mission_id=m.id),'[]'::jsonb),
    'completions',case when v_is_owner then coalesce((select jsonb_agg(jsonb_build_object('employee_id',mc.employee_id,'employee_name',e.display_name,'note',mc.note,'photo',mc.photo_data_url,'completed_at',mc.completed_at) order by mc.completed_at desc) from public.mission_completions mc join public.employees e on e.id=mc.employee_id where mc.mission_id=m.id),'[]'::jsonb) else '[]'::jsonb end,
    'completed_count',(select count(*) from public.mission_completions mc where mc.mission_id=m.id),
    'target_count',case when jsonb_array_length(m.target_employee_ids)=0 then(select count(*) from public.employees e where e.property_id=m.property_id and e.active and e.role<>'owner') else jsonb_array_length(m.target_employee_ids) end
  ) order by(m.due_at is not null and m.due_at<clock_timestamp() and c.completed_at is null) desc,m.due_at nulls last,m.created_at desc),'[]'::jsonb)
  into v_items from public.missions m left join public.mission_completions c on c.mission_id=m.id and c.employee_id=v_employee_id
  where m.property_id=v_property_id and m.active;
  return jsonb_build_object('ok',true,'missions',v_items,'employees',v_employees,'can_manage',v_is_owner);
end;
$$;

revoke all on function public.send_urgent_message(uuid,text),public.list_urgent_messages(uuid),public.acknowledge_urgent_message(uuid,uuid) from public;
grant execute on function public.send_urgent_message(uuid,text),public.list_urgent_messages(uuid),public.acknowledge_urgent_message(uuid,uuid) to anon,authenticated;

commit;
select '긴급메시지·미션 근무자 필터 준비 완료' as result;
