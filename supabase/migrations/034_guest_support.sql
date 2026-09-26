-- Removable guest support module. No existing message/attendance tables are altered.
begin;
create table if not exists public.guest_support_config(
 property_id uuid primary key references public.properties(id), slug uuid not null unique default gen_random_uuid(),
 enabled boolean not null default false, chat_enabled boolean not null default false,
 items jsonb not null default '[]', updated_at timestamptz not null default now());
create table if not exists public.guest_chat_rooms(
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id),
 guest_name text not null, check_in date not null, check_out date not null, room_number text,
 token_hash text not null unique, expires_at timestamptz not null, ip_hash text not null,
 status text not null default 'open' check(status in('open','closed')),
 assigned_key text, assigned_name text, assigned_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.guest_support_assets(
 id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id),
 room_id uuid references public.guest_chat_rooms(id), uploader_key text not null,
 object_path text not null unique, mime text not null, ready boolean not null default false,
 created_at timestamptz not null default now());
create table if not exists public.guest_chat_messages(
 seq bigint generated always as identity primary key, id uuid not null unique default gen_random_uuid(),
 room_id uuid not null references public.guest_chat_rooms(id), client_id uuid not null,
 sender_key text not null, sender_name text not null, sender_kind text not null check(sender_kind in('guest','staff','system')),
 body text not null default '', asset_id uuid references public.guest_support_assets(id),
 created_at timestamptz not null default now(), unique(room_id,sender_key,client_id));
create index if not exists guest_chat_messages_room_seq on public.guest_chat_messages(room_id,seq);
create index if not exists guest_chat_rooms_property_updated on public.guest_chat_rooms(property_id,updated_at desc);
create table if not exists public.guest_chat_reads(
 room_id uuid references public.guest_chat_rooms(id), actor_key text not null, last_seq bigint not null default 0,
 primary key(room_id,actor_key));
create table if not exists public.guest_chat_alert_preferences(
 actor_key text primary key, home_property_id uuid not null references public.properties(id),
 enabled boolean not null default false, property_ids uuid[] not null default '{}',
 days integer[] not null default array[0,1,2,3,4,5,6], start_time time, end_time time,
 updated_at timestamptz not null default now());
create table if not exists public.guest_chat_events(
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.guest_chat_rooms(id),
 message_id uuid unique, event_kind text not null check(event_kind in('started','message')),
 created_at timestamptz not null default now(), dispatch_finished boolean not null default false);
create unique index if not exists guest_chat_started_once on public.guest_chat_events(room_id) where event_kind='started';
create table if not exists public.guest_support_limits(key text primary key, window_at timestamptz not null, hits integer not null);

do $$declare t text;begin
 foreach t in array array['guest_support_config','guest_chat_rooms','guest_support_assets','guest_chat_messages','guest_chat_reads','guest_chat_alert_preferences','guest_chat_events','guest_support_limits'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 end loop;
end$$;

create or replace function omg_private.guest_actor(p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$declare a jsonb;begin
 select jsonb_build_object('key','owner:'||o.id,'id',o.id,'name',o.display_name,'property_id',s.property_id,'kind','owner') into a
 from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_token) and s.token_expires_at>now() and o.active;
 if a is null then
 select jsonb_build_object('key','employee:'||e.id,'id',e.id,'name',e.display_name,'property_id',s.property_id,'kind','staff') into a
 from public.work_sessions s join public.employees e on e.id=s.employee_id
 where s.login_token_hash=omg_private.token_hash(p_token) and s.token_expires_at>now() and e.active and s.status in('working','completed');
 end if;return a;end$$;
create or replace function omg_private.guest_can_access(p_home uuid,p_target uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select p_home=p_target or exists(select 1 from public.property_share_requests r where r.requester_property_id=p_home
 and r.target_property_id=p_target and r.status='approved' and 'messages'=any(r.requested_permissions));$$;
create or replace function omg_private.guest_limit(p_key text,p_limit integer,p_seconds integer) returns void
language plpgsql security definer set search_path='' as $$declare n integer;begin
 insert into public.guest_support_limits(key,window_at,hits) values(p_key,now(),1)
 on conflict(key) do update set hits=case when guest_support_limits.window_at<now()-make_interval(secs=>p_seconds) then 1 else guest_support_limits.hits+1 end,
 window_at=case when guest_support_limits.window_at<now()-make_interval(secs=>p_seconds) then now() else guest_support_limits.window_at end returning hits into n;
 if n>p_limit then raise exception '잠시 후 다시 시도해주세요.' using errcode='P0001';end if;
end$$;

-- All actions go through the Edge Function; neither guest nor app can bypass server validation.
create or replace function public.guest_support_rpc(p_action text,p_data jsonb default '{}',p_token uuid default null,p_guest_token uuid default null,p_ip_hash text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;prop uuid;room public.guest_chat_rooms%rowtype;cfg public.guest_support_config%rowtype;
 item jsonb;v_items jsonb;result jsonb;msgs jsonb;assets jsonb;roomid uuid;assetid uuid;eventid uuid;msgid uuid;
 guesttoken uuid;actor text;displayname text;kind text;body text;client uuid;ci date;co date;pref jsonb;target text;
 props uuid[];days integer[];st time;et time;seqid bigint;cursorid bigint;hasmore boolean;
begin
 if p_action='portal' then
 select * into cfg from public.guest_support_config where slug=(p_data->>'slug')::uuid and enabled;
 if not found then raise exception '이 QR 안내는 현재 운영하지 않습니다.';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'path',x.object_path,'mime',x.mime)),'[]') into assets
 from public.guest_support_assets x where x.ready and x.property_id=cfg.property_id and x.room_id is null
 and x.id in(select (j->>'asset_id')::uuid from jsonb_array_elements(cfg.items) j);
 return jsonb_build_object('ok',true,'name',(select name from public.properties where id=cfg.property_id),'chat_enabled',cfg.chat_enabled,'items',cfg.items,'assets',assets);
 end if;
 if p_action='start' then
 select * into cfg from public.guest_support_config where slug=(p_data->>'slug')::uuid and enabled and chat_enabled;
 if not found then raise exception '지금은 채팅을 시작할 수 없습니다.';end if;
 displayname:=btrim(coalesce(p_data->>'name',''));ci:=(p_data->>'check_in')::date;co:=(p_data->>'check_out')::date;
 if length(displayname) not between 1 and 60 or ci is null or co is null or co<ci or co>ci+90
 or co<current_date-1 or ci>current_date+30 or length(coalesce(p_data->>'room_number',''))>40 then raise exception '이름과 체크인·체크아웃 날짜를 확인해주세요.';end if;
 if length(p_ip_hash)<32 then raise exception '접속 정보를 확인하지 못했습니다.';end if;
 perform omg_private.guest_limit('start-ip:'||p_ip_hash,8,3600);
 perform omg_private.guest_limit('start-property:'||cfg.property_id,80,3600);
 -- A client-generated token makes a retried start safe after a lost HTTP response.
 guesttoken:=(p_data->>'new_token')::uuid;if guesttoken is null then raise exception '입장 정보를 확인해주세요.';end if;
 perform pg_advisory_xact_lock(hashtextextended(guesttoken::text,0));
 select * into room from public.guest_chat_rooms where token_hash=omg_private.token_hash(guesttoken);
 if found then
 if room.property_id<>cfg.property_id or room.expires_at<=now() then raise exception '다시 입장해주세요.';end if;
 select id into eventid from public.guest_chat_events where room_id=room.id and event_kind='started';
 return jsonb_build_object('ok',true,'room_id',room.id,'event_id',eventid);
 end if;
 insert into public.guest_chat_rooms(property_id,guest_name,check_in,check_out,room_number,token_hash,expires_at,ip_hash)
 values(cfg.property_id,displayname,ci,co,nullif(btrim(p_data->>'room_number'),''),omg_private.token_hash(guesttoken),
 least((co+2)::timestamp at time zone (select timezone from public.properties where id=cfg.property_id),now()+interval '60 days'),p_ip_hash) returning * into room;
 insert into public.guest_chat_events(room_id,event_kind) values(room.id,'started') returning id into eventid;
 return jsonb_build_object('ok',true,'room_id',room.id,'event_id',eventid);
 end if;
 a:=omg_private.guest_actor(p_token);home:=(a->>'property_id')::uuid;
 if a is not null then actor:=a->>'key';displayname:=a->>'name';kind:='staff';
 elsif p_guest_token is not null then
 select * into room from public.guest_chat_rooms where token_hash=omg_private.token_hash(p_guest_token) and expires_at>now();
 if not found then raise exception '대화 이용 시간이 만료되었습니다. QR로 다시 입장해주세요.';end if;
 actor:='guest:'||room.id;displayname:=room.guest_name;kind:='guest';
 else raise exception '로그인이 필요합니다.';end if;

 if p_action in('settings','save_settings','save_preferences') then
 if a->>'kind'<>'owner' or a is null then raise exception '관리자만 설정할 수 있습니다.';end if;
 insert into public.guest_support_config(property_id) values(home) on conflict do nothing;
 if p_action='save_settings' then
 v_items:=coalesce(p_data->'items','[]');
 if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)>20 then raise exception '안내 항목은 20개까지 등록할 수 있습니다.';end if;
 for item in select value from jsonb_array_elements(v_items) loop
 if length(btrim(coalesce(item->>'title',''))) not between 1 and 60 then raise exception '항목 제목을 입력해주세요.';end if;
 if not exists(select 1 from public.guest_support_assets x where x.id=(item->>'asset_id')::uuid and x.property_id=home and x.room_id is null and x.ready) then raise exception '안내 사진 또는 PDF를 첨부해주세요.';end if;
 end loop;
 update public.guest_support_config set enabled=coalesce((p_data->>'enabled')::boolean,false),chat_enabled=coalesce((p_data->>'chat_enabled')::boolean,false),
 items=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'asset_id',j->>'asset_id')),'[]') from jsonb_array_elements(v_items)j),updated_at=now() where property_id=home;
 elsif p_action='save_preferences' then
 for pref in select value from jsonb_array_elements(p_data->'preferences') loop
 target:=pref->>'actor_key';
 if not exists(select 1 from public.employees where 'employee:'||id=target and property_id=home and active)
 and not exists(select 1 from public.owners where 'owner:'||id=target and property_id=home and active) then raise exception '자기 지점 계정만 설정할 수 있습니다.';end if;
 select coalesce(array_agg(value::uuid),'{}') into props from jsonb_array_elements_text(pref->'property_ids');
 if exists(select 1 from unnest(props)x where not omg_private.guest_can_access(home,x)) then raise exception '공유 승인된 지점만 선택할 수 있습니다.';end if;
 select coalesce(array_agg(value::integer),'{}') into days from jsonb_array_elements_text(pref->'days');
 if not days<@array[0,1,2,3,4,5,6] or cardinality(days)=0 then raise exception '알림 요일을 선택해주세요.';end if;
 st:=nullif(pref->>'start_time','')::time;et:=nullif(pref->>'end_time','')::time;
 if (st is null)<>(et is null) then raise exception '시작·종료 시간을 모두 입력해주세요.';end if;
 insert into public.guest_chat_alert_preferences(actor_key,home_property_id,enabled,property_ids,days,start_time,end_time)
 values(target,home,coalesce((pref->>'enabled')::boolean,false),props,days,st,et)
 on conflict(actor_key) do update set enabled=excluded.enabled,property_ids=excluded.property_ids,days=excluded.days,start_time=excluded.start_time,end_time=excluded.end_time,updated_at=now();
 end loop;
 end if;
 select * into cfg from public.guest_support_config where property_id=home;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from (
 select 'employee:'||e.id actor_key,e.display_name name,coalesce(to_jsonb(n),'{}') preferences from public.employees e left join public.guest_chat_alert_preferences n on n.actor_key='employee:'||e.id where e.property_id=home and e.active and e.role<>'owner'
 union all select 'owner:'||o.id,o.display_name,coalesce(to_jsonb(n),'{}') from public.owners o left join public.guest_chat_alert_preferences n on n.actor_key='owner:'||o.id where o.property_id=home and o.active) x;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'path',x.object_path,'mime',x.mime)),'[]') into assets from public.guest_support_assets x where x.property_id=home and x.room_id is null and x.ready and x.id in(select (j->>'asset_id')::uuid from jsonb_array_elements(cfg.items)j);
 return jsonb_build_object('ok',true,'config',to_jsonb(cfg),'accounts',result,'assets',assets,'properties',
 (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'own',p.id=home) order by p.name),'[]') from public.properties p where omg_private.guest_can_access(home,p.id)));
 end if;

 if p_action='rooms' then
 if a is null then raise exception '직원 로그인이 필요합니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.updated_at desc,x.id desc),'[]') into result from(
 select r.id,r.property_id,p.name property_name,r.guest_name,r.check_in,r.check_out,r.room_number,r.status,r.assigned_key,r.assigned_name,r.updated_at,
 (select count(*) from public.guest_chat_messages m where m.room_id=r.id and m.sender_kind='guest' and m.seq>coalesce((select last_seq from public.guest_chat_reads where room_id=r.id and actor_key=actor),0)) unread,
 (select case when m.asset_id is not null and m.body='' then '사진' else m.body end from public.guest_chat_messages m where m.room_id=r.id order by m.seq desc limit 1) preview
 from public.guest_chat_rooms r join public.properties p on p.id=r.property_id where omg_private.guest_can_access(home,r.property_id)
 and (nullif(p_data->>'property_id','') is null or r.property_id=(p_data->>'property_id')::uuid)
 and (nullif(p_data->>'before_updated','') is null or (r.updated_at,r.id)<((p_data->>'before_updated')::timestamptz,(p_data->>'before_id')::uuid))
 order by r.updated_at desc,r.id desc limit 50)x;
 return jsonb_build_object('ok',true,'rooms',result,'actor',a,'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name)),'[]') from public.properties p where omg_private.guest_can_access(home,p.id)));
 end if;

 roomid:=nullif(p_data->>'room_id','')::uuid;
 if kind='staff' and roomid is not null then select * into room from public.guest_chat_rooms where id=roomid;end if;
 if roomid is not null and (room.id is null or room.id<>roomid or (kind='staff' and not omg_private.guest_can_access(home,room.property_id))) then raise exception '이 대화에 접근할 권한이 없습니다.';end if;
 prop:=case when roomid is null then home else room.property_id end;
 select * into cfg from public.guest_support_config where property_id=prop;
 if p_action in('send','upload_begin','upload_finish') and roomid is not null and (not coalesce(cfg.enabled and cfg.chat_enabled,false) or room.status<>'open') then raise exception '지금은 메시지를 보낼 수 없습니다.';end if;
 if p_action in('upload_begin','upload_finish') then
 if roomid is null and (a is null or a->>'kind'<>'owner') then raise exception '관리자만 안내파일을 올릴 수 있습니다.';end if;
 if p_action='upload_begin' then
 perform omg_private.guest_limit('upload:'||actor,20,3600);
 if p_data->>'mime' not in('image/jpeg','image/png','image/webp','application/pdf') or (roomid is not null and p_data->>'mime'='application/pdf') then raise exception '지원하지 않는 파일 형식입니다.';end if;
 assetid:=gen_random_uuid();
 insert into public.guest_support_assets(id,property_id,room_id,uploader_key,object_path,mime) values(assetid,prop,roomid,actor,prop||'/'||assetid,p_data->>'mime');
 return jsonb_build_object('ok',true,'asset_id',assetid,'path',prop||'/'||assetid);
 else
 update public.guest_support_assets set ready=true where id=(p_data->>'asset_id')::uuid and uploader_key=actor and property_id=prop and room_id is not distinct from roomid returning id into assetid;
 if assetid is null then raise exception '첨부파일을 확인하지 못했습니다.';end if;
 return jsonb_build_object('ok',true,'asset_id',assetid);
 end if;
 end if;
 if roomid is null then raise exception '대화를 선택해주세요.';end if;
 if p_action='send' then
 body:=btrim(coalesce(p_data->>'body',''));assetid:=nullif(p_data->>'asset_id','')::uuid;client:=(p_data->>'client_id')::uuid;
 if length(body)>4000 or (body='' and assetid is null) or client is null then raise exception '메시지 또는 사진을 입력해주세요.';end if;
 perform pg_advisory_xact_lock(hashtextextended(roomid::text,0));
 select id into msgid from public.guest_chat_messages where room_id=roomid and sender_key=actor and client_id=client;
 if msgid is null then
 perform omg_private.guest_limit('message:'||actor,30,60);
 if assetid is not null and not exists(select 1 from public.guest_support_assets x where x.id=assetid and x.ready and x.room_id=roomid and x.uploader_key=actor) then raise exception '이 대화에 첨부할 수 없는 사진입니다.';end if;
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body,asset_id) values(roomid,client,actor,displayname,kind,body,assetid) returning id into msgid;
 update public.guest_chat_rooms set updated_at=now(),assigned_key=case when kind='staff' and assigned_key is null then actor else assigned_key end,
 assigned_name=case when kind='staff' and assigned_key is null then displayname else assigned_name end,
 assigned_at=case when kind='staff' and assigned_key is null then now() else assigned_at end where id=roomid;
 if kind='guest' then insert into public.guest_chat_events(room_id,message_id,event_kind) values(roomid,msgid,'message');end if;
 end if;
 select id into eventid from public.guest_chat_events where message_id=msgid;
 return jsonb_build_object('ok',true,'message_id',msgid,'event_id',eventid);
 elsif p_action in('claim','release','close','reopen') then
 if a is null then raise exception '직원만 담당 상태를 변경할 수 있습니다.';end if;
 if p_action='claim' then
 update public.guest_chat_rooms set assigned_key=actor,assigned_name=displayname,assigned_at=now() where id=roomid and (assigned_key is null or assigned_key=actor or coalesce((p_data->>'takeover')::boolean,false));
 if not found then raise exception '다른 직원이 대응 중입니다. 담당 인계를 눌러주세요.';end if;
 elsif p_action='release' then update public.guest_chat_rooms set assigned_key=null,assigned_name=null,assigned_at=null where id=roomid and assigned_key=actor; if not found then raise exception '현재 담당자만 해제할 수 있습니다.';end if;
 elsif p_action='close' then update public.guest_chat_rooms set status='closed',updated_at=now() where id=roomid;
 else update public.guest_chat_rooms set status='open',updated_at=now() where id=roomid;end if;
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body) values(roomid,gen_random_uuid(),actor,displayname,'system',case p_action when 'claim' then '대응 담당 지정' when 'release' then '담당 해제' when 'close' then '대화 종료' else '대화 재개' end);
 return jsonb_build_object('ok',true);
 elsif p_action='read' then
 if a is null then return jsonb_build_object('ok',true);end if;
 select coalesce(max(seq),0) into seqid from public.guest_chat_messages where room_id=roomid and seq<=coalesce((p_data->>'last_seq')::bigint,0);
 insert into public.guest_chat_reads(room_id,actor_key,last_seq) values(roomid,actor,seqid) on conflict(room_id,actor_key) do update set last_seq=greatest(guest_chat_reads.last_seq,excluded.last_seq);
 return jsonb_build_object('ok',true);
 elsif p_action='messages' then
 cursorid:=coalesce((p_data->>'after_seq')::bigint,0);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.seq),'[]') into msgs from (
 select m.seq,m.id,m.body,m.asset_id,m.created_at,m.sender_kind,
 case when kind='guest' and m.sender_kind='staff' then '직원' else m.sender_name end sender_name,
 case when kind='guest' then null else m.sender_key end sender_key
 from public.guest_chat_messages m where m.room_id=roomid and m.seq>cursorid and (kind='staff' or m.sender_kind<>'system') order by m.seq limit 100)x;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'path',x.object_path,'mime',x.mime)),'[]') into assets from public.guest_support_assets x
 where x.ready and x.id in(select (j->>'asset_id')::uuid from jsonb_array_elements(msgs)j);
 return jsonb_build_object('ok',true,'messages',msgs,'assets',assets,'room',jsonb_build_object('id',room.id,'guest_name',room.guest_name,'check_in',room.check_in,'check_out',room.check_out,'room_number',room.room_number,'status',room.status,'property_name',(select name from public.properties where id=room.property_id),
 'assigned_name',case when kind='guest' then case when room.assigned_key is not null then '직원' end else room.assigned_name end,
 'assigned_key',case when kind='guest' then null else room.assigned_key end,'chat_enabled',coalesce(cfg.enabled and cfg.chat_enabled,false)),
 'actor_key',case when kind='guest' then 'guest:'||roomid else actor end);
 elsif p_action='retry_events' then
 perform omg_private.guest_limit('retry:'||actor,5,60);
 return jsonb_build_object('ok',true,'event_ids',(select coalesce(jsonb_agg(id),'[]') from(select e.id from public.guest_chat_events e where e.room_id=roomid and not dispatch_finished and e.created_at>now()-interval '5 minutes' order by created_at limit 10)x));
 end if;
 raise exception '지원하지 않는 요청입니다.';
end$$;

create or replace function public.get_guest_chat_dispatch(p_event_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;
 select coalesce(jsonb_agg(distinct x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}') into topics,deadlines from(
 select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,
 ((extract(epoch from least(ev.created_at+interval '5 minutes',
 (case when n.start_time is null or n.start_time=n.end_time then (local.t::date+1)::timestamp
 when n.start_time>n.end_time and local.t::time>=n.start_time then (local.t::date+1)+n.end_time
 else local.t::date+n.end_time end) at time zone p.timezone))*1000)::bigint)::text valid_until
 from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
 cross join lateral(select now() at time zone p.timezone t) local
 where n.enabled and r.property_id=any(n.property_ids) and omg_private.guest_can_access(n.home_property_id,r.property_id)
 and (case when n.start_time is not null and n.end_time<n.start_time and local.t::time<n.end_time then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)=any(n.days)
 and (n.start_time is null or n.start_time=n.end_time or (n.start_time<n.end_time and local.t::time>=n.start_time and local.t::time<n.end_time) or (n.start_time>n.end_time and (local.t::time>=n.start_time or local.t::time<n.end_time)))
 and (exists(select 1 from public.work_sessions s join public.employees e on e.id=s.employee_id where 'employee:'||e.id=n.actor_key and e.active and s.status='working' and s.token_expires_at>now())
 or exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id where 'owner:'||o.id=n.actor_key and o.active and s.token_expires_at>now()))
 )x;
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'message_type','guest_chat',
 'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
 'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label','현장 게스트',
 'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else '현장 게스트에게 새 메시지가 왔습니다. 채팅방을 확인해주세요.' end);
end$$;
create or replace function public.finish_guest_chat_dispatch(p_event_id uuid) returns void
language sql security definer set search_path='' as $$update public.guest_chat_events set dispatch_finished=true where id=p_event_id;$$;

revoke all on function omg_private.guest_actor(uuid),omg_private.guest_can_access(uuid,uuid),omg_private.guest_limit(text,integer,integer) from public,anon,authenticated;
revoke all on function public.guest_support_rpc(text,jsonb,uuid,uuid,text),public.get_guest_chat_dispatch(uuid),public.finish_guest_chat_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.guest_support_rpc(text,jsonb,uuid,uuid,text),public.get_guest_chat_dispatch(uuid),public.finish_guest_chat_dispatch(uuid) to service_role;
-- Bucket is private; only the Edge function signs assets after room/menu authorization.
do $$begin if to_regclass('storage.buckets') is not null then
 insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('guest-support','guest-support',false,4194304,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do nothing;
 end if;end$$;
commit;
select 'guest support installed' as migration_status;
