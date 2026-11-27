create table omg_private.home_display_preferences (
 owner_id uuid references public.owners(id) on delete cascade,
 property_id uuid references public.properties(id) on delete cascade,
 sections text[] not null, categories text[] not null,
 primary key(owner_id, property_id)
);
create table omg_private.home_booking_cancellations (
 property_id uuid references public.properties(id) on delete cascade,
 booking_id bigint not null,
 cancelled_at timestamptz not null default clock_timestamp(),
 primary key(property_id, booking_id)
);
alter table omg_private.home_display_preferences enable row level security;
alter table omg_private.home_booking_cancellations enable row level security;
revoke all on omg_private.home_display_preferences,omg_private.home_booking_cancellations from public,anon,authenticated;

create function omg_private.capture_home_booking_cancellation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='cancelled' and (tg_op='INSERT' or old.status is distinct from new.status) then
  insert into omg_private.home_booking_cancellations(property_id,booking_id) values(new.property_id,new.id)
  on conflict(property_id,booking_id) do update set cancelled_at=excluded.cancelled_at;
 end if;
 return new;
end $$;
revoke all on function omg_private.capture_home_booking_cancellation() from public,anon,authenticated;
-- Record actual transitions only; older cancelled bookings have no reliable cancellation time.
create trigger home_booking_cancellation after update of status on omg_private.online_bookings
 for each row execute function omg_private.capture_home_booking_cancellation();

create function public.oms_home_display(p_access_token uuid,p_preferences jsonb default null,p_feed boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor jsonb:=omg_private.guest_actor(p_access_token);
 owner_key uuid:=(actor->>'id')::uuid;
 property_key uuid:=(actor->>'property_id')::uuid;
 tz text;
 sections text[]; categories text[]; events jsonb:='[]';
begin
 if actor->>'kind' is distinct from 'owner' then return jsonb_build_object('ok',false,'message','관리자 로그인이 필요합니다.');end if;
 if p_preferences is not null then
  if jsonb_typeof(p_preferences->'sections') is distinct from 'array' or jsonb_typeof(p_preferences->'categories') is distinct from 'array' then
   return jsonb_build_object('ok',false,'message','홈화면 항목을 확인해주세요.');
  end if;
  select array(select value from jsonb_array_elements_text(p_preferences->'sections') with ordinality x(value,n)
    where value in ('staff','events') group by value order by min(n)),
   array(select distinct value from jsonb_array_elements_text(p_preferences->'categories') x(value)
    where value in ('ai','booking','cancel','attendance')) into sections,categories;
  insert into omg_private.home_display_preferences values(owner_key,property_key,sections,categories)
   on conflict(owner_id,property_id) do update set sections=excluded.sections,categories=excluded.categories;
 else
  select h.sections,h.categories into sections,categories from omg_private.home_display_preferences h
   where h.owner_id=owner_key and h.property_id=property_key;
  sections:=coalesce(sections,array['staff']);categories:=coalesce(categories,array['ai','booking','cancel','attendance']);
 end if;
 if p_feed and 'events'=any(sections) then
  select coalesce(timezone,'Asia/Seoul') into tz from public.properties where id=property_key;
  with items as (
   select 'booking' kind,b.booked_at at_time,b.guest_name label,b.id::text target,(b.booked_at at time zone tz)::date booking_day
   from omg_private.online_bookings b where b.property_id=property_key and 'booking'=any(categories) and b.booked_at>=now()-interval '30 days'
   union all
   select 'cancel',c.cancelled_at,b.guest_name,b.id::text,(b.booked_at at time zone tz)::date from omg_private.home_booking_cancellations c
   join omg_private.online_bookings b on b.property_id=c.property_id and b.id=c.booking_id
   where c.property_id=property_key and 'cancel'=any(categories) and c.cancelled_at>=now()-interval '30 days'
   union all
   select 'online_ai',o.updated_at,b.guest_name,b.id::text,null::date from omg_private.online_outbox o
   join omg_private.online_bookings b on b.property_id=o.property_id and b.id=o.booking_id
   where o.property_id=property_key and 'ai'=any(categories) and o.approved_by='ai:automatic' and o.status='sent' and o.updated_at>=now()-interval '30 days'
   union all
   select 'qr_ai',j.finished_at,r.guest_name,r.id::text,null::date from omg_private.ai_jobs j
   join public.guest_chat_rooms r on r.id=j.room_id
   where j.property_id=property_key and 'ai'=any(categories) and j.status='completed' and j.finished_at>=now()-interval '30 days'
   union all
   select t.kind,t.at_time,e.display_name,w.id::text,null::date from public.work_sessions w
   join public.employees e on e.id=w.employee_id
   cross join lateral (values('checkin',w.checkin_report_at),('checkout',w.checkout_report_at)) t(kind,at_time)
   where w.property_id=property_key and 'attendance'=any(categories) and t.at_time>=now()-interval '30 days'
  )
  select coalesce(jsonb_agg(to_jsonb(i) order by i.at_time desc,i.kind,i.target),'[]') into events
    from (select * from items order by at_time desc,kind,target limit 30)i;
 end if;
 return jsonb_build_object('ok',true,'property_id',property_key,'sections',sections,'categories',categories,'events',events);
end $$;
revoke all on function public.oms_home_display(uuid,jsonb,boolean) from public;
grant execute on function public.oms_home_display(uuid,jsonb,boolean) to anon,authenticated;

do $migration$
declare definition text; anchor text;
begin
 definition:=pg_get_functiondef('omg_private.pin_delivery_state(uuid,bigint,boolean)'::regprocedure);
 anchor:=$a$'due_at',due,'events',hist$a$;
 if strpos(definition,anchor)=0 then raise exception 'Missing PIN delivery result';end if;
 execute replace(definition,anchor,$b$'due_at',due,'sent_at',case when state='sent' then e.updated_at end,'events',hist$b$);
end $migration$;
