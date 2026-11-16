begin;
alter table omg_private.web_checkin_settings add column if not exists end_time time not null default '11:00';
create or replace function omg_private.web_checkin_in_window(arrival date,start_at time,end_at time,local_at timestamp)
returns boolean language sql immutable set search_path='' as $$
 select arrival is not null and end_at<='11:00'::time and local_at>=arrival+start_at and local_at<=(arrival+1)+end_at
$$;
revoke all on function omg_private.web_checkin_in_window(date,time,time,timestamp) from public,anon,authenticated;
create or replace function public.web_checkin_admin(p_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_token);home uuid;cfg omg_private.web_checkin_settings%rowtype;day date;src text;start_at time;end_at time;enabled_value boolean;bed_id bigint;
begin
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=(a->>'property_id')::uuid;
 select (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date,c.beds_property_id into day,bed_id from public.properties p left join omg_private.online_connections c on c.property_id=p.id where p.id=home;
 insert into omg_private.web_checkin_settings(property_id)values(home)on conflict do nothing;
 select * into cfg from omg_private.web_checkin_settings where property_id=home;
 if (now() at time zone (select coalesce(timezone,'Asia/Seoul') from public.properties where id=home))::time<cfg.release_time and (now() at time zone (select coalesce(timezone,'Asia/Seoul') from public.properties where id=home))::time<=cfg.end_time then day:=day-1;end if;
 if p_action='probe' then
  if bed_id is null then raise exception 'Beds24 연결을 먼저 설정해주세요.';end if;
  perform omg_private.guest_limit('web-checkin-probe:'||home,5,600);
 elsif p_action='record_probe' then
  if p_data->>'day'<>day::text or jsonb_typeof(p_data->'sources')<>'array' or jsonb_array_length(p_data->'sources')>100 then raise exception '연동 결과를 확인해주세요.';end if;
  update omg_private.web_checkin_settings set probe=p_data,tested_at=now() where property_id=home;
 elsif p_action='save' then
  src:=coalesce(p_data->>'source','');enabled_value:=coalesce((p_data->>'enabled')::boolean,false);start_at:=coalesce(nullif(p_data->>'release_time','')::time,'15:00'::time);
  end_at:=coalesce(nullif(p_data->>'end_time','')::time,cfg.end_time,'11:00'::time);
  if end_at>'11:00'::time or start_at>='24:00'::time then raise exception '종료 시각은 다음 날 오전 11시까지 설정할 수 있습니다.';end if;
  if src<>'' and src !~ '^(unit:name[2-8]|info:[A-Za-z0-9_-]{1,60})$' then raise exception '비밀번호 항목을 선택해주세요.';end if;
  select * into cfg from omg_private.web_checkin_settings where property_id=home;
  if enabled_value and (bed_id is null or src='' or cfg.tested_at is null or cfg.tested_at<now()-interval '1 day' or not exists(select 1 from jsonb_array_elements(coalesce(cfg.probe->'sources','[]'))x where x->>'source'=src and (x->>'count')::int>0)) then raise exception '연동 확인 후 비밀번호가 들어 있는 항목을 선택해주세요.';end if;
  update omg_private.web_checkin_settings set enabled=enabled_value,source=src,release_time=start_at,end_time=end_at,updated_at=now() where property_id=home;
 elsif p_action<>'read' then raise exception '지원하지 않는 요청입니다.';end if;
 select * into cfg from omg_private.web_checkin_settings where property_id=home;
 return jsonb_build_object('ok',true,'property_id',home,'day',day,'connected',bed_id is not null,'enabled',cfg.enabled,'source',cfg.source,'release_time',to_char(cfg.release_time,'HH24:MI'),'end_time',to_char(cfg.end_time,'HH24:MI'),'probe',cfg.probe,'tested_at',cfg.tested_at);
end$$;
revoke all on function public.web_checkin_admin(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.web_checkin_admin(uuid,text,jsonb) to service_role;

create or replace function public.web_checkin_gate(p_slug uuid,p_ip_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row record;local_at timestamp;days jsonb:='[]';
begin
 if p_ip_hash !~ '^[a-f0-9]{64}$' then return jsonb_build_object('ok',false,'message','접속을 확인하지 못했습니다.');end if;
 select p.id,p.name,p.timezone,s.source,s.release_time,s.end_time,c.beds_property_id into row
 from public.guest_support_config q join public.properties p on p.id=q.property_id
 join omg_private.web_checkin_settings s on s.property_id=p.id and s.enabled
 join omg_private.online_connections c on c.property_id=p.id and c.beds_property_id is not null
 where q.slug=p_slug and q.enabled;
 if not found then return jsonb_build_object('ok',false,'code','unavailable','message','현재 웹체크인을 이용할 수 없습니다. 직원에게 문의해주세요.');end if;
 perform omg_private.guest_limit('web-checkin-ip:'||p_ip_hash,20,900);
 perform omg_private.guest_limit('web-checkin-property:'||row.id,100,900);
 local_at:=now() at time zone coalesce(row.timezone,'Asia/Seoul');
 if omg_private.web_checkin_in_window(local_at::date,row.release_time,row.end_time,local_at) then days:=days||jsonb_build_array(local_at::date);end if;
 if omg_private.web_checkin_in_window(local_at::date-1,row.release_time,row.end_time,local_at) then days:=days||jsonb_build_array(local_at::date-1);end if;
 if jsonb_array_length(days)=0 then return jsonb_build_object('ok',false,'code','not_open','message','웹체크인은 체크인 당일 '||to_char(row.release_time,'HH24:MI')||'부터 다음 날 '||to_char(row.end_time,'HH24:MI')||'까지 가능합니다.');end if;
 return jsonb_build_object('ok',true,'property_id',row.id,'beds_property_id',row.beds_property_id,'name',row.name,'source',row.source,'day',days->>0,'days',days);
end$$;
revoke all on function public.web_checkin_gate(uuid,text) from public,anon,authenticated;
grant execute on function public.web_checkin_gate(uuid,text) to service_role;

create or replace function public.web_checkin_release(p_property uuid,p_source text,p_day date)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.properties p join public.guest_support_config q on q.property_id=p.id and q.enabled
 join omg_private.web_checkin_settings s on s.property_id=p.id and s.enabled and s.source=p_source
 where p.id=p_property and omg_private.web_checkin_in_window(p_day,s.release_time,s.end_time,now() at time zone coalesce(p.timezone,'Asia/Seoul')))
$$;
revoke all on function public.web_checkin_release(uuid,text,date) from public,anon,authenticated;
grant execute on function public.web_checkin_release(uuid,text,date) to service_role;

-- One persistent challenge per reservation. New devices cannot reset guesses.
create table if not exists omg_private.web_checkin_name_challenges(
 property_id uuid not null references public.properties(id) on delete cascade,
 booking_id bigint not null,
 token_hash text not null,
 fingerprint text not null,
 options jsonb not null,
 correct_id uuid not null,
 expires_at timestamptz not null default now()+interval '10 minutes',
 failed boolean not null default false,
 attempted uuid[] not null default '{}',
 verified boolean not null default false,
 created_at timestamptz not null default now(),
 primary key(property_id,booking_id)
);
alter table omg_private.web_checkin_name_challenges enable row level security;
revoke all on omg_private.web_checkin_name_challenges from public,anon,authenticated;

create or replace function public.web_checkin_identity(p_property uuid,p_booking bigint,p_token uuid,p_fingerprint text,p_name_matches boolean,p_can_challenge boolean,p_options jsonb default '[]',p_correct_id uuid default null,p_choice uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row omg_private.web_checkin_name_challenges%rowtype;
begin
 if p_token is null or p_booking is null or p_fingerprint !~ '^[a-f0-9]{64}$' then return jsonb_build_object('ok',false,'code','staff_required');end if;
 perform pg_advisory_xact_lock(hashtextextended('web-checkin-identity:'||p_property||':'||p_booking,0));
 -- Arrival access has ended by day two; retain locks for three days, then erase names.
 delete from omg_private.web_checkin_name_challenges where property_id=p_property and created_at<now()-interval '3 days';
 select * into row from omg_private.web_checkin_name_challenges where property_id=p_property and booking_id=p_booking for update;
 if not found then
  if p_name_matches and p_choice is null then return jsonb_build_object('ok',true,'verified',true);end if;
  if not coalesce(p_can_challenge,false) or p_choice is not null or p_correct_id is null or jsonb_typeof(p_options)<>'array' or jsonb_array_length(p_options)<>15 then return jsonb_build_object('ok',false,'code','staff_required');end if;
  if (select count(distinct x->>'id') from jsonb_array_elements(p_options)x)<>15 or (select count(distinct lower(x->>'label')) from jsonb_array_elements(p_options)x)<>15 or not exists(select 1 from jsonb_array_elements(p_options)x where x->>'id'=p_correct_id::text) then return jsonb_build_object('ok',false,'code','staff_required');end if;
  insert into omg_private.web_checkin_name_challenges(property_id,booking_id,token_hash,fingerprint,options,correct_id)values(p_property,p_booking,omg_private.token_hash(p_token),p_fingerprint,p_options,p_correct_id) returning * into row;
 end if;
 -- No new challenge on timeout, a different device, or a changed reservation.
 if row.failed or row.expires_at<=now() or row.token_hash<>omg_private.token_hash(p_token) or row.fingerprint<>p_fingerprint or not coalesce(p_can_challenge,false) then return jsonb_build_object('ok',false,'code','staff_required');end if;
 if row.verified then return jsonb_build_object('ok',true,'verified',true);end if;
 if p_choice is not null then
  if p_choice<>row.correct_id then
   if not exists(select 1 from jsonb_array_elements(row.options)x where x->>'id'=p_choice::text) then return jsonb_build_object('ok',false,'code','staff_required');end if;
   if not p_choice=any(row.attempted) then
    update omg_private.web_checkin_name_challenges set attempted=array_append(attempted,p_choice),failed=cardinality(attempted)+1>=2 where property_id=p_property and booking_id=p_booking returning * into row;
   end if;
   if row.failed then return jsonb_build_object('ok',false,'code','staff_required');end if;
   return jsonb_build_object('ok',true,'challenge',true,'options',row.options,'attempts_remaining',2-cardinality(row.attempted),'expires_at',row.expires_at);
  end if;
  update omg_private.web_checkin_name_challenges set verified=true where property_id=p_property and booking_id=p_booking;
  return jsonb_build_object('ok',true,'verified',true);
 end if;
 return jsonb_build_object('ok',true,'challenge',true,'options',row.options,'attempts_remaining',2-cardinality(row.attempted),'expires_at',row.expires_at);
end$$;
revoke all on function public.web_checkin_identity(uuid,bigint,uuid,text,boolean,boolean,jsonb,uuid,uuid) from public,anon,authenticated;
grant execute on function public.web_checkin_identity(uuid,bigint,uuid,text,boolean,boolean,jsonb,uuid,uuid) to service_role;
commit;
