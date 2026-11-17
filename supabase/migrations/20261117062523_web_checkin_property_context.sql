begin;
create or replace function public.web_checkin_admin(p_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb:=omg_private.guest_actor(p_token);home uuid;cfg omg_private.web_checkin_settings%rowtype;day date;src text;start_at time;end_at time;enabled_value boolean;bed_id bigint;
begin
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 -- Match the existing online-management permissions before reading or writing.
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 웹체크인 관리 권한이 없습니다.';end if;
 select (now() at time zone coalesce(p.timezone,'Asia/Seoul'))::date,c.beds_property_id into day,bed_id from public.properties p left join omg_private.online_connections c on c.property_id=p.id where p.id=home;
 insert into omg_private.web_checkin_settings(property_id)values(home)on conflict do nothing;
 select * into cfg from omg_private.web_checkin_settings where property_id=home;
 if (now() at time zone (select coalesce(timezone,'Asia/Seoul') from public.properties where id=home))::time<cfg.release_time and (now() at time zone (select coalesce(timezone,'Asia/Seoul') from public.properties where id=home))::time<=cfg.end_time then day:=day-1;end if;
 if p_action='probe' then
  if bed_id is null then raise exception 'Beds24 연결을 먼저 설정해주세요.';end if;
  perform omg_private.guest_limit('web-checkin-probe:'||home,5,600);
 elsif p_action='record_probe' then
  if p_data->>'day'<>day::text or jsonb_typeof(p_data->'sources')<>'array' or jsonb_array_length(p_data->'sources')>100 then raise exception '연동 결과를 확인해주세요.';end if;
  update omg_private.web_checkin_settings set probe=p_data-'property_id',tested_at=now() where property_id=home;
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
 return jsonb_build_object('ok',true,'property_id',home,'property_name',(select name from public.properties where id=home),'day',day,'connected',bed_id is not null,'enabled',cfg.enabled,'source',cfg.source,'release_time',to_char(cfg.release_time,'HH24:MI'),'end_time',to_char(cfg.end_time,'HH24:MI'),'probe',cfg.probe,'tested_at',cfg.tested_at);
end$$;
revoke all on function public.web_checkin_admin(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.web_checkin_admin(uuid,text,jsonb) to service_role;
commit;
