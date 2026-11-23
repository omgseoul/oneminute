create table omg_private.calendar_private_items (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.owners(id) on delete cascade,
 property_id uuid not null references public.properties(id) on delete cascade,
 kind text not null check(kind in ('task','event')),
 data jsonb not null check(jsonb_typeof(data)='object'),
 created_at timestamptz not null default now()
);
alter table omg_private.calendar_private_items enable row level security;
revoke all on omg_private.calendar_private_items from public,anon,authenticated;
create index calendar_private_items_owner on omg_private.calendar_private_items(owner_id,kind);

create function public.calendar_private_items_action(p_access_token uuid,p_action text,p_item jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 own uuid; prop uuid; item_id uuid; item_kind text; payload jsonb; rows jsonb;
begin
 select o.id,s.property_id into own,prop from public.owner_sessions s
 join public.owners o on o.id=s.owner_id and o.active
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp();
 if own is null then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.');end if;
 if p_action='list' then
  select coalesce(jsonb_agg(i.data||jsonb_build_object('id',i.id,'kind',i.kind,'private_owner_id',own,
   'property_id',i.property_id,'created_at',i.created_at,'creator_type','owner','creator_name','관리자',
   'can_edit',true,'owner_target',true,'target_employee_ids','[]'::jsonb,'active',coalesce((i.data->>'active')::boolean,true)) order by i.created_at desc),'[]'::jsonb)
  into rows from omg_private.calendar_private_items i where i.owner_id=own;
  return jsonb_build_object('ok',true,'items',rows);
 end if;
 item_id:=nullif(p_item->>'id','')::uuid;
 if p_action='save' then
  item_kind:=p_item->>'kind';
  if item_kind is null or item_kind not in ('task','event') or length(btrim(coalesce(p_item->>'title',''))) not between 1 and 160 then
   return jsonb_build_object('ok',false,'message','항목 이름과 종류를 확인해주세요.');
  end if;
  payload:=jsonb_build_object('title',btrim(p_item->>'title'));
  if item_kind='event' then
   if nullif(p_item->>'start_at','')::timestamptz is null or nullif(p_item->>'end_at','')::timestamptz is null
    or (p_item->>'end_at')::timestamptz <= (p_item->>'start_at')::timestamptz then
    return jsonb_build_object('ok',false,'message','일정 시간을 확인해주세요.');
   end if;
   payload:=payload||jsonb_build_object('start_at',(p_item->>'start_at')::timestamptz,'end_at',(p_item->>'end_at')::timestamptz,
    'all_day',coalesce((p_item->>'all_day')::boolean,false),'details',left(coalesce(p_item->>'details',''),4000));
  else
   payload:=payload||jsonb_build_object('due_at',nullif(p_item->>'due_at','')::timestamptz,'description',left(coalesce(p_item->>'description',''),4000),
    'priority',case when p_item->>'priority' in ('urgent','important') then p_item->>'priority' else 'normal' end,
    'timing',case when p_item->>'timing' in ('today','this_week') then p_item->>'timing' else 'anytime' end,
    'description_photo',p_item->'description_photo','photo_required',coalesce((p_item->>'photo_required')::boolean,false));
  end if;
  if item_id is null then
   insert into omg_private.calendar_private_items(owner_id,property_id,kind,data) values(own,prop,item_kind,payload);
  else
   update omg_private.calendar_private_items set data=payload||
    (data-'title'-'description'-'description_photo'-'due_at'-'priority'-'timing'-'photo_required'-'details'-'start_at'-'end_at'-'all_day')
   where id=item_id and owner_id=own and kind=item_kind;
  end if;
 elsif p_action='delete' then
  delete from omg_private.calendar_private_items where id=item_id and owner_id=own;
 elsif p_action='archive' then
  update omg_private.calendar_private_items set data=data||jsonb_build_object('active',false) where id=item_id and owner_id=own and kind='task';
 elsif p_action='complete' then
  update omg_private.calendar_private_items set data=data||jsonb_build_object('owner_completed_at',clock_timestamp(),
   'completions',jsonb_build_array(jsonb_build_object('employee_name','관리자','note',left(p_item->>'note',4000),'photo',p_item->'photo')))
  where id=item_id and owner_id=own and kind='task' and (data->>'photo_required' is distinct from 'true' or nullif(p_item->>'photo','') is not null);
 else return jsonb_build_object('ok',false,'message','지원하지 않는 작업입니다.');
 end if;
 if not found then return jsonb_build_object('ok',false,'message','처리할 항목을 확인해주세요.');end if;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.calendar_private_items_action(uuid,text,jsonb) from public;
grant execute on function public.calendar_private_items_action(uuid,text,jsonb) to anon,authenticated;
