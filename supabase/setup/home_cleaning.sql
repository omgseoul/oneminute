create schema if not exists omg_home_api;
revoke all on schema omg_home_api from public;
grant usage on schema omg_home_api to anon,authenticated,service_role;
-- Display preferences do not grant new reservation or message access.
create table if not exists omg_private.employee_cleaning_settings(
 employee_id uuid primary key references public.employees(id) on delete cascade,
 property_ids uuid[] not null,updated_at timestamptz not null default now()
);
alter table omg_private.employee_cleaning_settings enable row level security;
revoke all on omg_private.employee_cleaning_settings from public,anon,authenticated;
create or replace function omg_home_api.employee_cleaning_config(p_token uuid,p_employee uuid,p_action text,p_ids uuid[]) returns jsonb language plpgsql security definer set search_path='' as $$
declare home uuid;selected uuid[];options jsonb;begin
 select property_id into home from public.employees where id=p_employee and active;
 if home is null or not coalesce(omg_private.can_manage_shared_property(p_token,home,'account_settings'),false) then raise exception '근무자 계정관리 권한이 없습니다.';end if;
 if p_action not in('read','save') then raise exception '지원하지 않는 요청입니다.';end if;
 if p_action='save' then
  if p_ids is null or cardinality(p_ids)<1 or cardinality(p_ids)>100 or array_position(p_ids,null) is not null then raise exception '표시할 지점을 선택해주세요.';end if;
  if exists(select 1 from unnest(p_ids) x where not exists(select 1 from public.properties p where p.id=x and omg_private.guest_can_access(home,p.id) and (omg_private.can_manage_shared_property(p_token,p.id,'messages') or p.id=home))) then raise exception '조회 권한이 있는 지점만 선택할 수 있습니다.';end if;
  insert into omg_private.employee_cleaning_settings(employee_id,property_ids) values(p_employee,array(select distinct unnest(p_ids))) on conflict(employee_id)do update set property_ids=excluded.property_ids,updated_at=now();
 end if;
 select coalesce(s.property_ids,array[home]) into selected from (select 1) x left join omg_private.employee_cleaning_settings s on s.employee_id=p_employee;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'selected',p.id=any(selected)) order by p.management_number),'[]') into options from public.properties p where omg_private.guest_can_access(home,p.id) and (omg_private.can_manage_shared_property(p_token,p.id,'messages') or p.id=home);
 return jsonb_build_object('ok',true,'properties',options);
end$$;
create or replace function public.employee_cleaning_config(p_access_token uuid,p_employee_id uuid,p_action text default 'read',p_property_ids uuid[] default null) returns jsonb language sql security invoker set search_path='' as $$select omg_home_api.employee_cleaning_config(p_access_token,p_employee_id,p_action,p_property_ids)$$;
create or replace function omg_home_api.home_cleaning_summary(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;ids uuid[];result jsonb;begin
 a:=omg_private.guest_actor(p_token);if a is null then raise exception '로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 if a->>'kind'='staff' then select coalesce(s.property_ids,array[home]) into ids from(select 1)x left join omg_private.employee_cleaning_settings s on s.employee_id=(a->>'id')::uuid;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'timezone',p.timezone,'connected',c.beds_property_id is not null,'synced_at',c.synced_at,'days',(
  select jsonb_agg(jsonb_build_object('day',d.day,'count',case when c.beds_property_id is null then null else (select count(distinct omg_private.online_arrival_unit(p.id,b.data,b.id)) from omg_private.online_bookings b where b.property_id=p.id and b.departure=d.day and b.status in('new','confirmed')) end) order by d.day)
  from(select (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date+n as day from generate_series(0,2)n)d
 )) order by p.management_number),'[]') into result from public.properties p left join omg_private.online_connections c on c.property_id=p.id where omg_private.guest_can_access(home,p.id) and (ids is null or p.id=any(ids));
 return jsonb_build_object('ok',true,'properties',result);
end$$;
create or replace function public.home_cleaning_summary(p_access_token uuid) returns jsonb language sql security invoker set search_path='' as $$select omg_home_api.home_cleaning_summary(p_access_token)$$;
-- Read the saved result directly; no provider or AI request is made here.
create or replace function omg_home_api.get_cleaning_arrivals(p_token uuid,p_property uuid,p_day date) returns jsonb language plpgsql security definer set search_path='' as $$begin
 return omg_private.online_arrivals(p_token,'read',jsonb_build_object('property_id',p_property,'day',p_day));
end$$;
create or replace function public.get_cleaning_arrivals(p_access_token uuid,p_property_id uuid,p_day date) returns jsonb language sql security invoker set search_path='' as $$select omg_home_api.get_cleaning_arrivals(p_access_token,p_property_id,p_day)$$;
revoke all on function omg_home_api.employee_cleaning_config(uuid,uuid,text,uuid[]),public.employee_cleaning_config(uuid,uuid,text,uuid[]),omg_home_api.home_cleaning_summary(uuid),public.home_cleaning_summary(uuid),omg_home_api.get_cleaning_arrivals(uuid,uuid,date),public.get_cleaning_arrivals(uuid,uuid,date) from public;
grant execute on function omg_home_api.employee_cleaning_config(uuid,uuid,text,uuid[]),public.employee_cleaning_config(uuid,uuid,text,uuid[]),omg_home_api.home_cleaning_summary(uuid),public.home_cleaning_summary(uuid),omg_home_api.get_cleaning_arrivals(uuid,uuid,date),public.get_cleaning_arrivals(uuid,uuid,date) to anon,authenticated,service_role;
-- The retired staff emergency form cannot send via a bookmarked/older client either.
create or replace function public.send_urgent_message(p_access_token uuid,p_message text) returns jsonb language sql security invoker set search_path='' as $$select jsonb_build_object('ok',false,'message','긴급보고 기능은 종료되었습니다. 직원 메신저를 이용해주세요.')$$;

-- Revoke the earlier internal entry points; public RPCs now use the narrow API schema.
do $$declare signature text;begin
 foreach signature in array array['omg_private.employee_cleaning_config(uuid,uuid,text,uuid[])','omg_private.home_cleaning_summary(uuid)','omg_private.get_cleaning_arrivals(uuid,uuid,date)'] loop
  if to_regprocedure(signature) is not null then execute 'revoke all on function '||signature||' from public,anon,authenticated,service_role';end if;
 end loop;
end$$;
