-- Cache-first inbox date pagination and durable shared-credential sync protection.
begin;
create or replace function omg_private.online_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;c omg_private.online_connections%rowtype;bid bigint;v_from date;v_to date;tz text;v_id uuid;d omg_private.online_outbox%rowtype;latest bigint;begin
 a:=omg_private.guest_actor(p_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=coalesce(nullif(p_data->>'property_id','')::uuid,(a->>'property_id')::uuid);
 if home<>(a->>'property_id')::uuid and (not coalesce(omg_private.can_manage_shared_property(p_token,home,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,home,'messages'),false)) then raise exception '이 지점의 온라인 관리 권한이 없습니다.';end if;
 if p_data ? 'statuses' and (jsonb_typeof(p_data->'statuses')<>'array' or exists(select 1 from jsonb_array_elements_text(p_data->'statuses') x where x not in('new','confirmed','request','inquiry','cancelled','black','unknown'))) then raise exception '예약상태를 확인해주세요.';end if;
 insert into omg_private.online_connections(property_id) values(home) on conflict do nothing;
 select * into c from omg_private.online_connections where property_id=home;
 select timezone into tz from public.properties where id=home;
 if p_action='auth' then return jsonb_build_object('property_id',home,'actor',a->>'key','timezone',tz);end if;
 if p_action='reuse_connection' then
  if c.vault_id is not null then raise exception '이미 연결된 지점입니다.';end if;
  if not coalesce(omg_private.can_manage_shared_property(p_token,(p_data->>'source_property_id')::uuid,'property_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,(p_data->>'source_property_id')::uuid,'messages'),false) then raise exception '기존 연결을 사용할 권한이 없습니다.';end if;
  update omg_private.online_connections target set vault_id=source.vault_id,properties=source.properties,connected_at=now() from omg_private.online_connections source where target.property_id=home and source.property_id=(p_data->>'source_property_id')::uuid and source.vault_id is not null;
  if not found then raise exception '사용 가능한 기존 연결이 없습니다.';end if;
  insert into omg_private.online_audit(property_id,action,actor,detail)values(home,'reuse_connection',a->>'key',jsonb_build_object('source_property_id',p_data->>'source_property_id'));
  return omg_private.online_owner(p_token,'settings',p_data);
 end if;
 if p_action='settings' then
  return jsonb_build_object('ok',true,'branches',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p where omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages')),'connection_sources',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.management_number),'[]') from public.properties p join omg_private.online_connections co on co.property_id=p.id where p.id<>home and co.vault_id is not null and omg_private.can_manage_shared_property(p_token,p.id,'property_settings') and omg_private.can_manage_shared_property(p_token,p.id,'messages')),'property_name',(select name from public.properties where id=home),'timezone',tz,'connected',c.vault_id is not null,'beds_property_id',c.beds_property_id,'beds_name',c.beds_name,'properties',c.properties,'property_id',home,'webhook_key',c.webhook_key,'ai_mode',c.ai_mode,'synced_at',c.synced_at,'webhook_at',c.webhook_at,'last_error',c.last_error,'data_count',(select jsonb_array_length(data) from omg_private.ai_settings where property_id=home));
 elsif p_action='save_settings' then
  if coalesce(p_data->>'ai_mode','off') not in('off','approval') then raise exception '현재는 승인 후 발송 모드만 지원합니다.';end if;
  bid:=nullif(p_data->>'beds_property_id','')::bigint;
  if c.vault_id is null then raise exception 'Beds24를 먼저 연결해주세요.';end if;
  if bid is null or not exists(select 1 from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid) then raise exception '연결된 Beds24 숙소를 선택해주세요.';end if;
  if c.beds_property_id is not null and c.beds_property_id<>bid then raise exception '다른 지점은 화면 상단의 지점 선택에서 변경해주세요. 현재 지점의 기존 숙소 연결은 유지됩니다.';end if;
  if exists(select 1 from omg_private.online_connections where beds_property_id=bid and property_id<>home) then raise exception '이미 다른 OMS 지점에 연결된 숙소입니다. 상단에서 해당 지점을 선택해주세요.';end if;
  update omg_private.online_connections set beds_property_id=bid,beds_name=(select x->>'name' from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid),ai_mode=p_data->>'ai_mode' where property_id=home;
  insert into omg_private.online_audit(property_id,action,actor,detail)values(home,'settings',a->>'key',jsonb_build_object('beds_property_id',bid,'ai_mode',p_data->>'ai_mode'));
 elsif p_action='bookings' then
  v_from:=(p_data->>'from')::date;v_to:=(p_data->>'to')::date;
  if v_from is null or v_to is null or v_to<v_from or v_to-v_from>92 then raise exception '조회 기간은 최대 93일입니다.';end if;
  return jsonb_build_object('ok',true,'synced_at',c.synced_at,'bookings',(select coalesce(jsonb_agg(to_jsonb(x) order by x.arrival,x.guest_name),'[]') from (select b.* from omg_private.online_bookings b where b.property_id=home and (not (p_data ? 'statuses') or coalesce(nullif(b.status,''),'unknown') in(select jsonb_array_elements_text(p_data->'statuses'))) and (not coalesce((p_data->>'active_only')::boolean,false) or coalesce(b.status,'') not in('cancelled','black','inquiry')) and case p_data->>'basis' when 'booked' then (b.booked_at at time zone tz)::date between v_from and v_to when 'staying' then b.arrival<=v_from and b.departure>v_from and coalesce(b.status,'') not in('cancelled','black','inquiry') else b.arrival between v_from and v_to end order by b.arrival,b.id limit 2000)x));
 elsif p_action='inbox' then
  v_from:=nullif(p_data->>'message_from','')::date;v_to:=nullif(p_data->>'message_to','')::date;
  if (v_from is null)<>(v_to is null) or v_to<v_from then raise exception '조회 기간을 확인해주세요.';end if;
  return jsonb_build_object('ok',true,'synced_at',c.synced_at,'threads',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sent_at desc),'[]') from(select m.booking_id,max(m.sent_at) sent_at,count(*) filter(where m.source='guest' and m.read_at is null) unread,(array_agg(m.body order by m.sent_at desc,m.id desc))[1] preview,coalesce(b.guest_name,'예약 #'||m.booking_id) guest_name,b.room_name,b.arrival,b.departure,b.status,(select count(*) from omg_private.online_outbox o where o.property_id=home and o.booking_id=m.booking_id and o.status='draft') drafts from omg_private.online_messages m left join omg_private.online_bookings b on b.property_id=m.property_id and b.id=m.booking_id where m.property_id=home and (not (p_data ? 'statuses') or coalesce(nullif(b.status,''),'unknown') in(select jsonb_array_elements_text(p_data->'statuses'))) group by m.booking_id,b.guest_name,b.room_name,b.arrival,b.departure,b.status having v_from is null or (max(m.sent_at) at time zone coalesce(tz,'Asia/Seoul'))::date between v_from and v_to order by max(m.sent_at) desc,m.booking_id desc limit 300 offset greatest(0,least(15000,coalesce((p_data->>'offset')::int,0))))x));
 elsif p_action='thread' then
  bid:=(p_data->>'booking_id')::bigint;
  update omg_private.online_messages set read_at=now() where property_id=home and booking_id=bid and read_at is null;
  return jsonb_build_object('ok',true,'booking',(select to_jsonb(b) from omg_private.online_bookings b where b.property_id=home and b.id=bid),'messages',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sent_at,x.id),'[]') from(select id,source,body,sent_at,attachment_name from omg_private.online_messages where property_id=home and booking_id=bid order by sent_at desc,id desc limit 500)x),'outbox',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from(select ob.*,(select display_name from public.owners where 'owner:'||id=ob.approved_by) approved_name from omg_private.online_outbox ob where property_id=home and booking_id=bid order by created_at desc limit 50)x));
 elsif p_action='logs' then
  return jsonb_build_object('ok',true,'logs',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select ob.*,(select display_name from public.owners where 'owner:'||id=ob.approved_by) approved_name from omg_private.online_outbox ob where property_id=home order by created_at desc limit 200)x),'events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select action,actor,detail,created_at from omg_private.online_audit where property_id=home order by created_at desc limit 50)x));
 elsif p_action='prepare_send' then
  bid:=(p_data->>'booking_id')::bigint;v_id:=(p_data->>'id')::uuid;
  if c.beds_property_id is null or not exists(select 1 from omg_private.online_bookings where property_id=home and id=bid) then raise exception '예약정보를 먼저 새로고침해주세요.';end if;
  if length(btrim(coalesce(p_data->>'body',''))) not between 1 and 4000 then raise exception '메시지는 1~4,000자로 입력해주세요.';end if;
  perform pg_advisory_xact_lock(hashtextextended(home::text||':'||bid,909));
  select * into d from omg_private.online_outbox where id=v_id for update;
  if found then
   if d.property_id<>home or d.booking_id<>bid then raise exception '접근할 수 없는 발송 건입니다.';end if;
   if d.status<>'draft' then return jsonb_build_object('ok',true,'skip',true,'status',d.status);end if;
   select id into latest from omg_private.online_messages where property_id=home and booking_id=bid order by sent_at desc,id desc limit 1;
   if d.based_on is distinct from latest or exists(select 1 from omg_private.online_outbox other where other.property_id=home and other.booking_id=bid and other.id<>d.id and other.status in('sending','sent','uncertain') and other.created_at>=d.created_at) then update omg_private.online_outbox set status='stale',updated_at=now(),error='새 메시지가 도착해 초안을 다시 확인해야 합니다.' where id=v_id;return jsonb_build_object('ok',true,'skip',true,'status','stale');end if;
   update omg_private.online_outbox set status='sending',body=btrim(p_data->>'body'),approved_by=a->>'key',updated_at=now() where id=v_id;
  else
   insert into omg_private.online_outbox(id,property_id,booking_id,body,kind,status,actor,approved_by)values(v_id,home,bid,btrim(p_data->>'body'),'manual','sending',a->>'key',a->>'key');
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
 elsif p_action='reject' then
  update omg_private.online_outbox set status='rejected',approved_by=a->>'key',updated_at=now() where id=(p_data->>'id')::uuid and property_id=home and status='draft';
 else raise exception '지원하지 않는 요청입니다.';
 end if;
 return jsonb_build_object('ok',true);
end$$;

create table if not exists omg_private.online_sync_state (
 scope text primary key, lease uuid, leased_until timestamptz, next_at timestamptz,
 last_success timestamptz, updated_at timestamptz not null default now()
);
alter table omg_private.online_sync_state enable row level security;
revoke all on omg_private.online_sync_state from public,anon,authenticated;
-- Called only by the authenticated edge service; authorization remains in online_owner.
create or replace function public.online_sync_control(p_action text,p_property uuid,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.online_connections%rowtype;s omg_private.online_sync_state%rowtype;k text;account_key text;wait_seconds int;begin
 select * into c from omg_private.online_connections where property_id=p_property;
 if c.vault_id is null then raise exception 'Beds24 연결을 확인해주세요.';end if;
 account_key:='account:'||c.vault_id;
 if p_action='metadata_needed' then
  return coalesce((select jsonb_agg(x.id) from (select value::bigint id from jsonb_array_elements_text(p_data->'ids'))x left join omg_private.online_bookings b on b.property_id=p_property and b.id=x.id where b.id is null or b.updated_at<now()-interval '24 hours'),'[]');
 end if;
 if p_action in('check','cooldown') then
  insert into omg_private.online_sync_state(scope)values(account_key) on conflict do nothing;
  if p_action='cooldown' then
   wait_seconds:=greatest(1,least(3600,coalesce((p_data->>'seconds')::int,300)));
   update omg_private.online_sync_state set next_at=greatest(coalesce(next_at,now()),now()+make_interval(secs=>wait_seconds)),updated_at=now() where scope=account_key;
  end if;
  select * into s from omg_private.online_sync_state where scope=account_key;
  return jsonb_build_object('skip',coalesce(s.next_at>now(),false),'retry_at',s.next_at);
 end if;
 k:=p_property::text||':'||left(p_data->>'scope',150);
 if k is null then raise exception '동기화 범위를 확인해주세요.';end if;
 insert into omg_private.online_sync_state(scope)values(k) on conflict do nothing;
 select * into s from omg_private.online_sync_state where scope=k for update;
 if p_action='begin' then
  if s.leased_until>now() or s.next_at>now() then return jsonb_build_object('skip',true,'retry_at',greatest(s.leased_until,s.next_at));end if;
  if exists(select 1 from omg_private.online_sync_state where scope=account_key and next_at>now()) then return jsonb_build_object('skip',true,'limited',true,'retry_at',(select next_at from omg_private.online_sync_state where scope=account_key));end if;
  update omg_private.online_sync_state set lease=gen_random_uuid(),leased_until=now()+interval '5 minutes',updated_at=now() where scope=k returning * into s;
  return jsonb_build_object('lease',s.lease,'last_success',s.last_success);
 elsif p_action='finish' then
  update omg_private.online_sync_state set leased_until=null,next_at=now()+make_interval(secs=>case when coalesce((p_data->>'success')::boolean,false) then case when p_data->>'scope' like 'thread:%' then 60 else 300 end else 60 end),last_success=case when coalesce((p_data->>'success')::boolean,false) then now() else last_success end,updated_at=now() where scope=k and lease=(p_data->>'lease')::uuid;
 else raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true);
end$$;
revoke all on function public.online_sync_control(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.online_sync_control(text,uuid,jsonb) to service_role;
commit;
