begin;
create table if not exists omg_private.web_checkin_devices(
 property_id uuid not null references public.properties(id) on delete cascade,
 device_hash text not null, name_attempts uuid[] not null default '{}',
 blocked boolean not null default false, updated_at timestamptz not null default now(),
 primary key(property_id,device_hash)
);
create table if not exists omg_private.web_checkin_flows(
 property_id uuid not null references public.properties(id) on delete cascade,
 token_hash text not null, device_hash text not null, mode text not null,
 stage text not null, booking_id bigint, fingerprint text, input_name text,
 expires_at timestamptz not null default now()+interval '20 minutes',
 primary key(property_id,token_hash)
);
create table if not exists omg_private.web_checkin_booking_guards(
 property_id uuid not null references public.properties(id) on delete cascade,
 booking_id bigint not null, fingerprint text not null,
 date_attempts uuid[] not null default '{}', choice_attempts uuid[] not null default '{}',
 options jsonb not null default '[]', correct_id uuid, blocked boolean not null default false,
 document_used boolean not null default false, created_at timestamptz not null default now(),
 primary key(property_id,booking_id)
);
alter table omg_private.web_checkin_devices enable row level security;
alter table omg_private.web_checkin_flows enable row level security;
alter table omg_private.web_checkin_booking_guards enable row level security;
revoke all on omg_private.web_checkin_devices,omg_private.web_checkin_flows,omg_private.web_checkin_booking_guards from public,anon,authenticated;

create or replace function public.web_checkin_flow(p_property uuid,p_token uuid,p_device uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare d omg_private.web_checkin_devices%rowtype; s omg_private.web_checkin_flows%rowtype;g omg_private.web_checkin_booking_guards%rowtype;
 th text:=omg_private.token_hash(p_token);dh text:=omg_private.token_hash(p_device); attempt uuid;bid bigint;fp text;choice uuid;
 denied jsonb:='{"ok":false,"code":"staff_required","message":"직원과의 채팅으로 예약을 확인하여 주십시오."}';
begin
 if p_token is null or p_device is null or p_property is null then return denied;end if;
 perform pg_advisory_xact_lock(hashtextextended('wc-device:'||p_property||':'||dh,0));
 insert into omg_private.web_checkin_devices(property_id,device_hash)values(p_property,dh)on conflict do nothing;
 select * into d from omg_private.web_checkin_devices where property_id=p_property and device_hash=dh for update;
 if d.blocked then return denied||jsonb_build_object('code','device_blocked');end if;
 if p_action='device' then return jsonb_build_object('ok',true,'name_remaining',3-cardinality(d.name_attempts));end if;
 delete from omg_private.web_checkin_flows where property_id=p_property and expires_at<now()-interval '1 day';
 delete from omg_private.web_checkin_booking_guards where property_id=p_property and created_at<now()-interval '3 days';
 select * into s from omg_private.web_checkin_flows where property_id=p_property and token_hash=th for update;
 if p_action='start' and not found then
  bid:=nullif(p_data->>'booking_id','')::bigint;fp:=p_data->>'fingerprint';
  if bid is not null and (fp is null or fp !~ '^[a-f0-9]{64}$') then return denied;end if;
  insert into omg_private.web_checkin_flows(property_id,token_hash,device_hash,mode,stage,booking_id,fingerprint)
   values(p_property,th,dh,case when bid is null then 'document' else 'reference' end,case when bid is null then 'name' else 'dates' end,bid,fp) returning * into s;
 elsif not found then return denied;end if;
 if s.device_hash<>dh or s.expires_at<=now() or s.stage='failed' then return denied;end if;
 if p_action='name' then
  if s.stage<>'name' then return denied;end if;
  attempt:=nullif(p_data->>'attempt_id','')::uuid;if attempt is null then return denied;end if;
  if not coalesce((p_data->>'matched')::boolean,false) then
   if not attempt=any(d.name_attempts) then
    update omg_private.web_checkin_devices set name_attempts=array_append(name_attempts,attempt),blocked=cardinality(name_attempts)+1>=3,updated_at=now() where property_id=p_property and device_hash=dh returning * into d;
   end if;
   if d.blocked then return denied||jsonb_build_object('code','device_blocked');end if;
   return jsonb_build_object('ok',true,'stage','name','mode',s.mode,'name_remaining',3-cardinality(d.name_attempts),'message','예약명단에 없습니다. 이름을 확인해주세요.');
  end if;
  if length(coalesce(p_data->>'name','')) not between 2 and 100 then return denied;end if;
  update omg_private.web_checkin_flows set input_name=p_data->>'name',stage='fallback_dates' where property_id=p_property and token_hash=th returning * into s;
 elsif p_action='bind' then
  if s.stage<>'fallback_dates' then return denied;end if;
  bid:=(p_data->>'booking_id')::bigint;fp:=p_data->>'fingerprint';
  if bid is null or fp is null or fp !~ '^[a-f0-9]{64}$' then return denied;end if;
  update omg_private.web_checkin_flows set booking_id=bid,fingerprint=fp,stage='dates' where property_id=p_property and token_hash=th returning * into s;
 end if;
 if s.booking_id is not null then
  perform pg_advisory_xact_lock(hashtextextended('wc-booking:'||p_property||':'||s.booking_id,0));
  insert into omg_private.web_checkin_booking_guards(property_id,booking_id,fingerprint)values(p_property,s.booking_id,s.fingerprint)on conflict do nothing;
  select * into g from omg_private.web_checkin_booking_guards where property_id=p_property and booking_id=s.booking_id for update;
  if g.blocked or g.fingerprint<>s.fingerprint or exists(select 1 from omg_private.web_checkin_name_challenges old where old.property_id=p_property and old.booking_id=s.booking_id and old.failed) then return denied;end if;
 end if;
 if p_action='dates' then
  if s.stage<>'dates' or s.booking_id is null then return denied;end if;
  attempt:=nullif(p_data->>'attempt_id','')::uuid;if attempt is null then return denied;end if;
  if not coalesce((p_data->>'matched')::boolean,false) then
   if not attempt=any(g.date_attempts) then update omg_private.web_checkin_booking_guards set date_attempts=array_append(date_attempts,attempt),blocked=cardinality(date_attempts)+1>=2 where property_id=p_property and booking_id=s.booking_id returning * into g;end if;
   if g.blocked then return denied;end if;
   return jsonb_build_object('ok',true,'stage','dates','mode',s.mode,'date_remaining',2-cardinality(g.date_attempts),'message','체크인·체크아웃 날짜를 확인해주세요.');
  end if;
  if s.mode='reference' and jsonb_array_length(g.options)=0 then
   if jsonb_typeof(p_data->'options')<>'array' or jsonb_array_length(p_data->'options')<>10 or (select count(distinct x->>'id') from jsonb_array_elements(p_data->'options')x)<>10 or (select count(distinct lower(x->>'label')) from jsonb_array_elements(p_data->'options')x)<>10 or not exists(select 1 from jsonb_array_elements(p_data->'options')x where x->>'id'=p_data->>'correct_id') then return denied;end if;
   update omg_private.web_checkin_booking_guards set options=p_data->'options',correct_id=(p_data->>'correct_id')::uuid where property_id=p_property and booking_id=s.booking_id returning * into g;
  end if;
  update omg_private.web_checkin_flows set stage=case when mode='reference' then 'choice' else 'upload' end where property_id=p_property and token_hash=th returning * into s;
 elsif p_action='choice' then
  if s.stage<>'choice' then return denied;end if;choice:=nullif(p_data->>'choice_id','')::uuid;
  if choice is null or not exists(select 1 from jsonb_array_elements(g.options)x where x->>'id'=choice::text) then return denied;end if;
  if choice<>g.correct_id then
   if not choice=any(g.choice_attempts) then update omg_private.web_checkin_booking_guards set choice_attempts=array_append(choice_attempts,choice),blocked=cardinality(choice_attempts)+1>=2 where property_id=p_property and booking_id=s.booking_id returning * into g;end if;
   if g.blocked then return denied;end if;
  else update omg_private.web_checkin_flows set stage='verified',input_name=null where property_id=p_property and token_hash=th returning * into s;end if;
 elsif p_action='claim_image' then
  if s.stage<>'upload' or g.document_used then return denied;end if;
  perform omg_private.guest_limit('wc-image:'||p_property,30,86400);
  update omg_private.web_checkin_booking_guards set document_used=true where property_id=p_property and booking_id=s.booking_id;
  update omg_private.web_checkin_flows set stage='processing' where property_id=p_property and token_hash=th returning * into s;
 elsif p_action='document' then
  if s.stage<>'processing' then return denied;end if;
  if not coalesce((p_data->>'matched')::boolean,false) then
   update omg_private.web_checkin_flows set stage='failed',input_name=null where property_id=p_property and token_hash=th;
   update omg_private.web_checkin_booking_guards set blocked=true where property_id=p_property and booking_id=s.booking_id;return denied;
  end if;
  update omg_private.web_checkin_flows set stage='verified',input_name=null where property_id=p_property and token_hash=th returning * into s;
 elsif p_action not in ('device','start','read','name','bind') then return denied;end if;
 return jsonb_build_object('ok',true,'stage',s.stage,'mode',s.mode,'booking_id',s.booking_id,'fingerprint',s.fingerprint,'input_name',s.input_name,'name_remaining',3-cardinality(d.name_attempts),'date_remaining',2-cardinality(g.date_attempts),'attempts_remaining',2-cardinality(g.choice_attempts),'options',g.options,'rejected_ids',g.choice_attempts);
end$$;
revoke all on function public.web_checkin_flow(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.web_checkin_flow(uuid,uuid,uuid,text,jsonb) to service_role;
commit;
