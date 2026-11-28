begin;
-- Custom owner sessions are checked here; financial reads never rely on browser filters.
create or replace function public.online_revenue(p_access_token uuid,p_properties uuid[],p_from date,p_to date,p_basis text default 'staying',p_statuses text[] default array['new','confirmed'])
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb; p uuid; result jsonb;
begin
 a:=omg_private.guest_actor(p_access_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 if coalesce(cardinality(p_properties),0) not between 1 and 50 or array_position(p_properties,null) is not null then raise exception '조회할 지점을 선택해주세요.';end if;
 foreach p in array p_properties loop
  if not coalesce(omg_private.can_manage_shared_property(p_access_token,p,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_access_token,p,'messages'),false) then raise exception '이 지점의 매출 조회 권한이 없습니다.';end if;
 end loop;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>730 then raise exception '조회 기간은 최대 2년입니다.';end if;
 if p_basis is null or p_basis not in('staying','arrival','booked') then raise exception '집계 기준을 확인해주세요.';end if;
 if p_statuses is null or array_position(p_statuses,null) is not null or exists(select 1 from unnest(p_statuses)s where s not in('new','confirmed','request','inquiry','cancelled','black','unknown')) then raise exception '예약상태를 확인해주세요.';end if;
 with selected as (
  select b.property_id,b.id,b.arrival,b.departure,(b.booked_at at time zone coalesce(pr.timezone,'Asia/Seoul'))::date booked,
   coalesce(nullif(btrim(b.channel),''),'미등록') channel,coalesce(nullif(b.status,''),'unknown') status,
   case when jsonb_typeof(b.data->'price')='number' and (b.data->>'price')::numeric>=0 then (b.data->>'price')::numeric end price,
   case when b.data->>'currency' ~ '^[A-Z]{3}$' then b.data->>'currency' else 'UNKNOWN' end currency
  from omg_private.online_bookings b join public.properties pr on pr.id=b.property_id
  where b.property_id=any(p_properties) and coalesce(nullif(b.status,''),'unknown')=any(p_statuses)
   and case p_basis when 'arrival' then b.arrival between p_from and p_to
    when 'booked' then (b.booked_at at time zone coalesce(pr.timezone,'Asia/Seoul'))::date between p_from and p_to
    else b.arrival<=p_to and b.departure>p_from end
 ) select jsonb_build_object('ok',true,'rows',coalesce(jsonb_agg(to_jsonb(s) order by arrival,id),'[]')) into result from selected s;
 if jsonb_array_length(result->'rows')>50000 then raise exception '예약이 많습니다. 기간이나 지점을 나누어 조회해주세요.';end if;
 return result||jsonb_build_object('properties',(
  select coalesce(jsonb_agg(jsonb_build_object('id',pr.id,'name',pr.name,'connected',c.beds_property_id is not null,'synced_at',c.synced_at,
   'coverage',(select coalesce(jsonb_agg(jsonb_build_object('from',split_part(s.scope,':',4),'to',split_part(s.scope,':',5),'at',s.last_success)),'[]') from omg_private.online_sync_state s
    where s.scope like pr.id::text||':bookings:'||p_basis||':%' and s.last_success is not null and s.scope ~ ':[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9]{4}-[0-9]{2}-[0-9]{2}$')
  ) order by pr.management_number),'[]') from public.properties pr left join omg_private.online_connections c on c.property_id=pr.id where pr.id=any(p_properties)
 ));
end $$;
revoke all on function public.online_revenue(uuid,uuid[],date,date,text,text[]) from public;
grant execute on function public.online_revenue(uuid,uuid[],date,date,text,text[]) to anon,authenticated,service_role;
comment on function public.online_revenue(uuid,uuid[],date,date,text,text[]) is 'Read-only booking revenue with custom owner session and per-property permissions. No credentials, contact details, or guest names returned.';
commit;
