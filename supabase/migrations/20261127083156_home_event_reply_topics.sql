alter table omg_private.ai_jobs add column reply_topic text;

-- Keep the existing finalizer's locks, billing, and permission checks intact.
do $$
declare
 definition text:=pg_get_functiondef('omg_private.ai_finish(uuid,uuid,jsonb)'::regprocedure);
 anchor text:=$anchor$status=case when disposition='answer' then 'completed' else 'handoff' end,reason=why$anchor$;
begin
 if strpos(definition,anchor)=0 then raise exception 'AI finalizer update not found'; end if;
 execute replace(definition,anchor,
  anchor||$topic$,reply_topic=case when disposition='answer' then left(nullif(btrim(p_result->>'reply_topic'),''),120) end$topic$);
end $$;

create or replace function public.oms_home_display_v2(p_access_token uuid,p_preferences jsonb default null,p_feed boolean default false,p_property_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor jsonb:=omg_private.guest_actor(p_access_token);
 owner_key uuid:=(actor->>'id')::uuid;
 property_key uuid:=(actor->>'property_id')::uuid;
 show_today boolean; branches jsonb:='[]';
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
  show_today:=case p_preferences->>'today_visible' when 'false' then false when 'true' then true else
    coalesce((select h.today_visible from omg_private.home_display_preferences h where h.owner_id=owner_key and h.property_id=property_key),true) end;
  insert into omg_private.home_display_preferences(owner_id,property_id,sections,categories,today_visible)
   values(owner_key,property_key,sections,categories,show_today)
   on conflict(owner_id,property_id) do update set sections=excluded.sections,categories=excluded.categories,today_visible=excluded.today_visible;
 else
  select h.sections,h.categories,h.today_visible into sections,categories,show_today from omg_private.home_display_preferences h
   where h.owner_id=owner_key and h.property_id=property_key;
  sections:=coalesce(sections,array['staff']);categories:=coalesce(categories,array['ai','booking','cancel','attendance']);
 end if;
 if p_feed and 'events'=any(sections) then
  with permissions as materialized (
   select p.id,p.name,p.management_number,coalesce(p.timezone,'Asia/Seoul') tz,
    (p.id=property_key or (coalesce(omg_private.can_manage_shared_property(p_access_token,p.id,'messages'),false)
      and coalesce(omg_private.can_manage_shared_property(p_access_token,p.id,'property_settings'),false))) online,
    (p.id=property_key or coalesce(omg_private.guest_can_access(property_key,p.id),false)) qr,
    (p.id=property_key or coalesce(omg_private.can_manage_shared_property(p_access_token,p.id,'attendance'),false)) attendance
   from public.properties p
   where p.id=property_key or exists(select 1 from public.property_share_requests r
      where r.requester_property_id=property_key and r.target_property_id=p.id and r.status='approved')
  ), allowed as (
   select * from permissions where online or qr or attendance
  ), selected as (
   select * from allowed where id=any(coalesce(p_property_ids,array[property_key]))
  ), items as (
   select 'booking' kind,b.booked_at at_time,b.guest_name label,b.id::text target,s.id property_id,
    (b.booked_at at time zone s.tz)::date booking_day,null::text reply_topic
   from selected s join omg_private.online_bookings b on b.property_id=s.id
   where s.online and 'booking'=any(categories) and b.booked_at>=now()-interval '30 days'
   union all
   select 'cancel',c.cancelled_at,b.guest_name,b.id::text,s.id,(b.booked_at at time zone s.tz)::date,null::text
   from selected s join omg_private.home_booking_cancellations c on c.property_id=s.id
   join omg_private.online_bookings b on b.property_id=c.property_id and b.id=c.booking_id
   where s.online and 'cancel'=any(categories) and c.cancelled_at>=now()-interval '30 days'
   union all
   select 'online_ai',o.updated_at,b.guest_name,b.id::text,s.id,null::date,
    coalesce(nullif(o.result->>'reply_topic',''),(
     select left(btrim(source.value->>'title'),120)
     from jsonb_array_elements(coalesce(o.result->'parts','[]')) with ordinality part(value,n)
     cross join lateral jsonb_array_elements_text(coalesce(part.value->'sources','[]')) with ordinality matched(id,n)
     join lateral jsonb_array_elements(coalesce(o.result->'sources','[]')) source(value)
       on source.value->>'id'=matched.id
     where nullif(btrim(source.value->>'title'),'') is not null
     order by part.n,matched.n limit 1))
   from selected s join omg_private.online_outbox o on o.property_id=s.id
   join omg_private.online_bookings b on b.property_id=o.property_id and b.id=o.booking_id
   where s.online and 'ai'=any(categories) and o.approved_by='ai:automatic' and o.status='sent' and o.updated_at>=now()-interval '30 days'
   union all
   select 'qr_ai',j.finished_at,r.guest_name,r.id::text,s.id,null::date,j.reply_topic
   from selected s join omg_private.ai_jobs j on j.property_id=s.id
   join public.guest_chat_rooms r on r.id=j.room_id and r.property_id=s.id
   where s.qr and 'ai'=any(categories) and j.status='completed' and j.finished_at>=now()-interval '30 days'
   union all
   select t.kind,t.at_time,e.display_name,w.id::text,s.id,null::date,null::text
   from selected s join public.work_sessions w on w.property_id=s.id
   join public.employees e on e.id=w.employee_id
   cross join lateral (values('checkin',w.checkin_report_at),('checkout',w.checkout_report_at)) t(kind,at_time)
   where s.attendance and 'attendance'=any(categories) and t.at_time>=now()-interval '30 days'
  ), recent as (
   select * from items order by at_time desc,property_id,kind,target limit 30
  )
  select (select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name) order by a.id=property_key desc,a.management_number),'[]') from allowed a),
   coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('property_name',s.name,'timezone',s.tz,
    'arrival',b.arrival,'departure',b.departure,'channel',b.channel)
    order by i.at_time desc,i.property_id,i.kind,i.target),'[]')
   into branches,events
   from recent i join selected s on s.id=i.property_id
   left join omg_private.online_bookings b on b.property_id=i.property_id
    and b.id=case when i.kind in ('booking','cancel','online_ai') then i.target::bigint end;
 end if;
 return jsonb_build_object('ok',true,'property_id',property_key,'sections',sections,'categories',categories,'events',events,'branches',branches,'today_visible',coalesce(show_today,true));
end $$;
