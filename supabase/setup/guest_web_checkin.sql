begin;
create table if not exists omg_private.web_checkin_settings(
 property_id uuid primary key references public.properties(id) on delete cascade,
 enabled boolean not null default false,
 source text not null default '',
 release_time time not null default '15:00',
 probe jsonb not null default '{}',
 tested_at timestamptz,
 updated_at timestamptz not null default now()
);
alter table omg_private.web_checkin_settings enable row level security;
revoke all on omg_private.web_checkin_settings from public,anon,authenticated;

create or replace function public.web_checkin_admin(p_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_token);home uuid;cfg omg_private.web_checkin_settings%rowtype;day date;src text;start_at time;enabled_value boolean;bed_id bigint;
begin
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=(a->>'property_id')::uuid;
 select (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date,c.beds_property_id into day,bed_id from public.properties p left join omg_private.online_connections c on c.property_id=p.id where p.id=home;
 insert into omg_private.web_checkin_settings(property_id)values(home)on conflict do nothing;
 if p_action='probe' then
  if bed_id is null then raise exception 'Beds24 연결을 먼저 설정해주세요.';end if;
  perform omg_private.guest_limit('web-checkin-probe:'||home,5,600);
 elsif p_action='record_probe' then
  if p_data->>'day'<>day::text or jsonb_typeof(p_data->'sources')<>'array' or jsonb_array_length(p_data->'sources')>100 then raise exception '연동 결과를 확인해주세요.';end if;
  update omg_private.web_checkin_settings set probe=p_data,tested_at=now() where property_id=home;
 elsif p_action='save' then
  src:=coalesce(p_data->>'source','');enabled_value:=coalesce((p_data->>'enabled')::boolean,false);start_at:=coalesce(nullif(p_data->>'release_time','')::time,'15:00'::time);
  if src<>'' and src !~ '^(unit:name[2-8]|info:[A-Za-z0-9_-]{1,60})$' then raise exception '비밀번호 항목을 선택해주세요.';end if;
  select * into cfg from omg_private.web_checkin_settings where property_id=home;
  if enabled_value and (bed_id is null or src='' or cfg.tested_at is null or cfg.tested_at<now()-interval '1 day' or not exists(select 1 from jsonb_array_elements(coalesce(cfg.probe->'sources','[]'))x where x->>'source'=src and (x->>'count')::int>0)) then raise exception '연동 확인 후 비밀번호가 들어 있는 항목을 선택해주세요.';end if;
  update omg_private.web_checkin_settings set enabled=enabled_value,source=src,release_time=start_at,updated_at=now() where property_id=home;
 elsif p_action<>'read' then raise exception '지원하지 않는 요청입니다.';end if;
 select * into cfg from omg_private.web_checkin_settings where property_id=home;
 return jsonb_build_object('ok',true,'property_id',home,'day',day,'connected',bed_id is not null,'enabled',cfg.enabled,'source',cfg.source,'release_time',to_char(cfg.release_time,'HH24:MI'),'probe',cfg.probe,'tested_at',cfg.tested_at);
end$$;
revoke all on function public.web_checkin_admin(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.web_checkin_admin(uuid,text,jsonb) to service_role;

create or replace function public.web_checkin_gate(p_slug uuid,p_ip_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare row record;local_at timestamp;
begin
 if p_ip_hash !~ '^[a-f0-9]{64}$' then return jsonb_build_object('ok',false,'message','접속을 확인하지 못했습니다.');end if;
 select p.id,p.name,p.timezone,s.source,s.release_time,c.beds_property_id into row
 from public.guest_support_config q join public.properties p on p.id=q.property_id
 join omg_private.web_checkin_settings s on s.property_id=p.id and s.enabled
 join omg_private.online_connections c on c.property_id=p.id and c.beds_property_id is not null
 where q.slug=p_slug and q.enabled;
 if not found then return jsonb_build_object('ok',false,'code','unavailable','message','현재 웹체크인을 이용할 수 없습니다. 직원에게 문의해주세요.');end if;
 perform omg_private.guest_limit('web-checkin-ip:'||p_ip_hash,20,900);
 perform omg_private.guest_limit('web-checkin-property:'||row.id,100,900);
 local_at:=now() at time zone coalesce(row.timezone,'Asia/Seoul');
 if local_at::time<row.release_time then return jsonb_build_object('ok',false,'code','not_open','message','객실 출입 정보는 체크인 당일 '||to_char(row.release_time,'HH24:MI')||'부터 확인할 수 있습니다.');end if;
 return jsonb_build_object('ok',true,'property_id',row.id,'beds_property_id',row.beds_property_id,'name',row.name,'source',row.source,'day',local_at::date);
end$$;
revoke all on function public.web_checkin_gate(uuid,text) from public,anon,authenticated;
grant execute on function public.web_checkin_gate(uuid,text) to service_role;

create or replace function public.web_checkin_release(p_property uuid,p_source text,p_day date)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.properties p join public.guest_support_config q on q.property_id=p.id and q.enabled
 join omg_private.web_checkin_settings s on s.property_id=p.id and s.enabled and s.source=p_source
 where p.id=p_property and (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date=p_day and (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::time>=s.release_time)
$$;
revoke all on function public.web_checkin_release(uuid,text,date) from public,anon,authenticated;
grant execute on function public.web_checkin_release(uuid,text,date) to service_role;

-- Existing QR entry stays the only public discovery route; no settings or codes leak.
do $patch$
declare f text;needle text:=$n$'chat_enabled',cfg.chat_enabled,'items',cfg.items$n$;
begin
 f:=pg_get_functiondef('public.guest_support_rpc(text,jsonb,uuid,uuid,text)'::regprocedure);
 if strpos(f,'''web_checkin_enabled''')=0 then
  if strpos(f,needle)=0 then raise exception 'Guest portal anchor changed';end if;
  execute replace(f,needle,$n$'chat_enabled',cfg.chat_enabled,'web_checkin_enabled',exists(select 1 from omg_private.web_checkin_settings wc where wc.property_id=cfg.property_id and wc.enabled),'items',cfg.items$n$);
 end if;
end $patch$;
commit;
