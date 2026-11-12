-- Beds24 inbox: credentials stay in Vault; every public RPC is service-role only.
create table omg_private.online_connections (
 property_id uuid primary key references public.properties(id) on delete cascade,
 vault_id uuid, beds_property_id bigint unique, beds_name text, properties jsonb not null default '[]',
 webhook_key text not null default encode(extensions.gen_random_bytes(32),'hex'),
 ai_mode text not null default 'off' check(ai_mode in('off','approval')),
 connected_at timestamptz, synced_at timestamptz, webhook_at timestamptz, last_error text,
 created_at timestamptz not null default now()
);
create table omg_private.online_bookings (
 property_id uuid references public.properties(id) on delete cascade, id bigint,
 guest_name text not null, arrival date, departure date, booked_at timestamptz,
 status text, room_name text, channel text, data jsonb not null, updated_at timestamptz not null default now(),
 primary key(property_id,id)
);
create index online_booking_arrival on omg_private.online_bookings(property_id,arrival);
create index online_booking_created on omg_private.online_bookings(property_id,booked_at);
create table omg_private.online_messages (
 property_id uuid references public.properties(id) on delete cascade, id bigint, booking_id bigint not null,
 source text not null, body text not null, sent_at timestamptz not null, attachment_name text,
 read_at timestamptz, notice_id uuid, created_at timestamptz not null default now(), primary key(property_id,id)
);
create index online_message_booking on omg_private.online_messages(property_id,booking_id,sent_at);
create table omg_private.online_outbox (
 id uuid primary key, property_id uuid references public.properties(id) on delete cascade, booking_id bigint not null,
 body text not null, kind text not null check(kind in('manual','ai')), status text not null check(status in('generating','draft','sending','sent','failed','uncertain','rejected','stale')),
 based_on bigint, result jsonb, error text, actor text, approved_by text,
 period date, reserved_micro bigint not null default 0, charged_micro bigint not null default 0,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index online_ai_message on omg_private.online_outbox(property_id,based_on) where kind='ai';
create index online_outbox_property on omg_private.online_outbox(property_id,created_at desc);
create table omg_private.online_webhooks (
 property_id uuid references public.properties(id) on delete cascade, booking_id bigint,
 revision bigint not null default 1, claimed_revision bigint, lease uuid, leased_until timestamptz,
 attempts integer not null default 0, next_at timestamptz not null default now(), error text,
 primary key(property_id,booking_id)
);
create table omg_private.online_audit (
 id uuid primary key default gen_random_uuid(),property_id uuid references public.properties(id) on delete cascade,
 action text not null, actor text, detail jsonb not null default '{}', created_at timestamptz not null default now()
);
alter table omg_private.online_connections enable row level security;
alter table omg_private.online_bookings enable row level security;
alter table omg_private.online_messages enable row level security;
alter table omg_private.online_outbox enable row level security;
alter table omg_private.online_webhooks enable row level security;
alter table omg_private.online_audit enable row level security;
revoke all on omg_private.online_connections,omg_private.online_bookings,omg_private.online_messages,omg_private.online_outbox,omg_private.online_webhooks,omg_private.online_audit from public,anon,authenticated;

create function omg_private.online_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;c omg_private.online_connections%rowtype;bid bigint;v_from date;v_to date;tz text;v_id uuid;d omg_private.online_outbox%rowtype;latest bigint;begin
 a:=omg_private.guest_actor(p_token);
 if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;
 home:=(a->>'property_id')::uuid;
 insert into omg_private.online_connections(property_id) values(home) on conflict do nothing;
 select * into c from omg_private.online_connections where property_id=home;
 select timezone into tz from public.properties where id=home;
 if p_action='auth' then return jsonb_build_object('property_id',home,'actor',a->>'key','timezone',tz);end if;
 if p_action='settings' then
  return jsonb_build_object('ok',true,'property_name',(select name from public.properties where id=home),'timezone',tz,'connected',c.vault_id is not null,'beds_property_id',c.beds_property_id,'beds_name',c.beds_name,'properties',c.properties,'property_id',home,'webhook_key',c.webhook_key,'ai_mode',c.ai_mode,'synced_at',c.synced_at,'webhook_at',c.webhook_at,'last_error',c.last_error,'data_count',(select jsonb_array_length(data) from omg_private.ai_settings where property_id=home));
 elsif p_action='save_settings' then
  if coalesce(p_data->>'ai_mode','off') not in('off','approval') then raise exception '현재는 승인 후 발송 모드만 지원합니다.';end if;
  bid:=nullif(p_data->>'beds_property_id','')::bigint;
  if bid is null or not exists(select 1 from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid) then raise exception '연결된 Beds24 숙소를 선택해주세요.';end if;
  if c.beds_property_id is not null and c.beds_property_id<>bid then raise exception '다른 숙소로 변경하려면 연결 해제 후 다시 연결해주세요.';end if;
  update omg_private.online_connections set beds_property_id=bid,beds_name=(select x->>'name' from jsonb_array_elements(c.properties)x where (x->>'id')::bigint=bid),ai_mode=p_data->>'ai_mode' where property_id=home;
  insert into omg_private.online_audit(property_id,action,actor,detail)values(home,'settings',a->>'key',jsonb_build_object('beds_property_id',bid,'ai_mode',p_data->>'ai_mode'));
 elsif p_action='bookings' then
  v_from:=(p_data->>'from')::date;v_to:=(p_data->>'to')::date;
  if v_from is null or v_to is null or v_to<v_from or v_to-v_from>92 then raise exception '조회 기간은 최대 93일입니다.';end if;
  return jsonb_build_object('ok',true,'synced_at',c.synced_at,'bookings',(select coalesce(jsonb_agg(to_jsonb(x) order by x.arrival,x.guest_name),'[]') from (select b.* from omg_private.online_bookings b where b.property_id=home and (not coalesce((p_data->>'active_only')::boolean,false) or coalesce(b.status,'') not in('cancelled','black','inquiry')) and case p_data->>'basis' when 'booked' then (b.booked_at at time zone tz)::date between v_from and v_to when 'staying' then b.arrival<=v_from and b.departure>v_from and coalesce(b.status,'') not in('cancelled','black','inquiry') else b.arrival between v_from and v_to end order by b.arrival,b.id limit 2000)x));
 elsif p_action='inbox' then
  return jsonb_build_object('ok',true,'threads',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sent_at desc),'[]') from(select m.booking_id,max(m.sent_at) sent_at,count(*) filter(where m.source='guest' and m.read_at is null) unread,(array_agg(m.body order by m.sent_at desc,m.id desc))[1] preview,coalesce(b.guest_name,'예약 #'||m.booking_id) guest_name,b.room_name,b.arrival,b.departure,(select count(*) from omg_private.online_outbox o where o.property_id=home and o.booking_id=m.booking_id and o.status='draft') drafts from omg_private.online_messages m left join omg_private.online_bookings b on b.property_id=m.property_id and b.id=m.booking_id where m.property_id=home group by m.booking_id,b.guest_name,b.room_name,b.arrival,b.departure order by max(m.sent_at) desc limit 300)x));
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

create function omg_private.online_internal(p_action text,p_property uuid,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.online_connections%rowtype;sid uuid;x jsonb;bid bigint;mid bigint;notice uuid;w omg_private.online_webhooks%rowtype;d omg_private.online_outbox%rowtype;history jsonb;dataset jsonb;s omg_private.ai_settings%rowtype;v_period date;v_res bigint;v_cost bigint;budget bigint;it bigint;ot bigint;ct bigint;wt bigint;begin
 if p_action='worker_verify' then return to_jsonb(exists(select 1 from vault.decrypted_secrets where name='oms_guest_ai_worker_secret' and decrypted_secret=p_data->>'secret' and length(p_data->>'secret')=64));end if;
 if p_action='maintenance' then
  for d in select * from omg_private.online_outbox where status='generating' and created_at<now()-interval '3 minutes' limit 20 loop
   perform omg_private.online_internal('draft_finish',d.property_id,jsonb_build_object('id',d.id,'estimated',true,'error','AI 응답 중 연결이 끊겼습니다. 직접 답변해주세요.'));
  end loop;
  return coalesce((select jsonb_agg(property_id) from (select co.property_id from omg_private.online_connections co join vault.decrypted_secrets vs on vs.id=co.vault_id where co.beds_property_id is not null and (coalesce((vs.decrypted_secret::jsonb->>'expiresAt')::numeric,0)<extract(epoch from now())*1000 or exists(select 1 from omg_private.online_messages m where m.property_id=co.property_id and m.notice_id is not null and m.created_at>now()-interval '5 minutes')) limit 10)pending),'[]');
 end if;
 if p_action='claim' then
  -- Never automatically retry an ambiguous OTA send.
  update omg_private.online_outbox set status='uncertain',error='발송 결과 확인 필요 · 대화내역을 새로고침하세요.',updated_at=now() where status='sending' and updated_at<now()-interval '2 minutes';
  select * into w from omg_private.online_webhooks where next_at<=now() and (leased_until is null or leased_until<now()) order by next_at for update skip locked limit 1;
  if not found then return jsonb_build_object('empty',true);end if;
  update omg_private.online_webhooks set lease=gen_random_uuid(),leased_until=now()+interval '90 seconds',claimed_revision=revision,attempts=attempts+1 where property_id=w.property_id and booking_id=w.booking_id returning * into w;
  return to_jsonb(w);
 end if;
 select * into c from omg_private.online_connections where property_id=p_property;
 if not found then raise exception '온라인 관리 설정이 없습니다.';end if;
 if p_action='credentials' then
  return jsonb_build_object('beds_property_id',c.beds_property_id,'ai_mode',c.ai_mode,'secret',(select decrypted_secret::jsonb from vault.decrypted_secrets where id=c.vault_id),'timezone',(select timezone from public.properties where id=p_property));
 elsif p_action='connect' then
  select vault_id into sid from omg_private.online_connections where property_id=p_property for update;
  if sid is null then sid:=vault.create_secret((p_data->'secret')::text,'oms_beds24_'||p_property,'Beds24 credential');else perform vault.update_secret(sid,(p_data->'secret')::text);end if;
  update omg_private.online_connections set vault_id=sid,properties=coalesce(p_data->'properties',properties),connected_at=now(),last_error=null where property_id=p_property;
  insert into omg_private.online_audit(property_id,action,actor)values(p_property,'connected',p_data->>'actor');
 elsif p_action='token' then
  perform vault.update_secret(c.vault_id,(p_data->'secret')::text);
 elsif p_action='webhook' then
  if length(coalesce(p_data->>'key',''))<>64 or p_data->>'key'<>c.webhook_key or c.beds_property_id is null then raise exception 'invalid_webhook';end if;
  bid:=(p_data->>'booking_id')::bigint;if bid<=0 or bid is null then raise exception 'invalid_booking';end if;
  insert into omg_private.online_webhooks(property_id,booking_id)values(p_property,bid) on conflict(property_id,booking_id) do update set revision=omg_private.online_webhooks.revision+1,next_at=least(omg_private.online_webhooks.next_at,now());
  update omg_private.online_connections set webhook_at=now() where property_id=p_property;
 elsif p_action='ack' then
  if coalesce(p_data->>'error','')<>'' then
   update omg_private.online_webhooks set error=left(p_data->>'error',250),leased_until=null,next_at=now()+least(interval '30 minutes',interval '30 seconds'*power(2,least(attempts,6))) where property_id=p_property and booking_id=(p_data->>'booking_id')::bigint and lease=(p_data->>'lease')::uuid;
   update omg_private.online_connections set last_error=left(p_data->>'error',250) where property_id=p_property;
  else
   delete from omg_private.online_webhooks where property_id=p_property and booking_id=(p_data->>'booking_id')::bigint and lease=(p_data->>'lease')::uuid and revision=claimed_revision;
   update omg_private.online_webhooks set leased_until=null,next_at=now() where property_id=p_property and booking_id=(p_data->>'booking_id')::bigint and lease=(p_data->>'lease')::uuid;
  end if;
 elsif p_action='bookings' then
  for x in select value from jsonb_array_elements(p_data->'items') loop
   if (x->>'propertyId')::bigint is distinct from c.beds_property_id then raise exception '숙소가 일치하지 않습니다.';end if;
   insert into omg_private.online_bookings(property_id,id,guest_name,arrival,departure,booked_at,status,room_name,channel,data)
   values(p_property,(x->>'id')::bigint,left(btrim(coalesce(x->>'firstName','')||' '||coalesce(x->>'lastName','')),200),nullif(x->>'arrival','')::date,nullif(x->>'departure','')::date,nullif(x->>'bookingTime','')::timestamptz,x->>'status',coalesce((select coalesce((select unit->>'name' from jsonb_array_elements(coalesce(room->'units','[]')) unit where unit->>'id'=x->>'unitId' limit 1),room->>'name') from jsonb_array_elements(c.properties) prop cross join lateral jsonb_array_elements(coalesce(prop->'roomTypes','[]')) room where prop->>'id'=c.beds_property_id::text and room->>'id'=x->>'roomId' limit 1),x->>'roomName','객실 ID '||(x->>'roomId')),coalesce(x->>'apiSource',x->>'referer'),x)
   on conflict(property_id,id) do update set guest_name=excluded.guest_name,arrival=excluded.arrival,departure=excluded.departure,booked_at=excluded.booked_at,status=excluded.status,room_name=excluded.room_name,channel=excluded.channel,data=excluded.data,updated_at=now();
  end loop;
 elsif p_action='messages' then
  for x in select value from jsonb_array_elements(p_data->'items') loop
   bid:=(x->>'bookingId')::bigint;mid:=(x->>'id')::bigint;
   if (x->>'propertyId')::bigint is distinct from c.beds_property_id or mid is null or bid is null then raise exception '메시지 숙소가 일치하지 않습니다.';end if;
   insert into omg_private.online_messages(property_id,id,booking_id,source,body,sent_at,attachment_name,read_at)
   values(p_property,mid,bid,x->>'source',coalesce(x->>'message',''),(x->>'time')::timestamptz,x->>'attachmentName',case when coalesce((p_data->>'notify')::boolean,false) then null else now() end) on conflict do nothing;
   if found and x->>'source'='guest' and coalesce((p_data->>'notify')::boolean,false) and (x->>'time')::timestamptz>=c.created_at then
    insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
    select p.business_id,p.id,'system','[OMS-ONLINE:'||bid||']'||E'\n'||coalesce((select guest_name from omg_private.online_bookings where property_id=p_property and id=bid),'예약 #'||bid)||E'\n'||left(coalesce(nullif(x->>'message',''),'첨부파일 메시지'),700),'normal','general','beds24',p_property||':'||mid from public.properties p where p.id=p_property returning id into notice;
    insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
    select notice,'owner:'||o.id,'owner',o.id from public.owners o where o.property_id=p_property and o.active;
    update omg_private.online_messages set notice_id=notice where property_id=p_property and id=mid;
   end if;
  end loop;
 elsif p_action='synced' then
  update omg_private.online_connections set synced_at=now(),last_error=null where property_id=p_property;
 elsif p_action='finish_send' then
  update omg_private.online_outbox set status=p_data->>'status',error=p_data->>'error',result=coalesce(result,'{}')||coalesce(p_data->'result','{}'),updated_at=now() where property_id=p_property and id=(p_data->>'id')::uuid and status='sending';
 elsif p_action='draft_claim' then
  bid:=(p_data->>'booking_id')::bigint;
  perform pg_advisory_xact_lock(hashtextextended(p_property::text||':'||bid,910));
  select to_jsonb(m) into x from omg_private.online_messages m where property_id=p_property and booking_id=bid order by sent_at desc,id desc limit 1;
  if x is null or x->>'source'<>'guest' then return jsonb_build_object('skip',true);end if;mid:=(x->>'id')::bigint;
  if exists(select 1 from omg_private.online_outbox where property_id=p_property and based_on=mid and kind='ai') then return jsonb_build_object('skip',true);end if;
  select * into s from omg_private.ai_settings where property_id=p_property;
  if not found or s.data='[]' then raise exception 'Property에서 AI 자동답변 DATA를 먼저 등록해주세요.';end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',n::text,'title',j->>'title','answer',j->>'answer')),'[]') into dataset from jsonb_array_elements(s.data) with ordinality t(j,n) where nullif(btrim(j->>'answer'),'') is not null;
  select jsonb_agg(jsonb_build_object('role',case source when 'guest' then 'user' else 'assistant' end,'content',left(body,4000)) order by sent_at,id) into history from(select * from omg_private.online_messages where property_id=p_property and booking_id=bid and source in('host','guest') order by sent_at desc,id desc limit 16)h;
  v_res:=ceil((octet_length(s.prompt)+octet_length(dataset::text)+octet_length(history::text)+20000)*0.125+2048*0.5)::bigint;v_period:=omg_private.ai_month();
  select balance_micro into budget from omg_private.ai_wallets where property_id=p_property and enabled for update;
  insert into omg_private.ai_usage_month(property_id,month)values(p_property,v_period)on conflict do nothing;
  if budget is null or budget-coalesce((select sum(reserved_micro) from omg_private.ai_jobs where property_id=p_property and status='leased'),0)<v_res or (select wallet.monthly_limit_micro-u.used_micro-u.reserved_micro from omg_private.ai_wallets wallet join omg_private.ai_usage_month u using(property_id) where wallet.property_id=p_property and u.month=v_period)<v_res then raise exception 'AI 크레딧 또는 월 사용 한도를 확인해주세요.';end if;
  insert into omg_private.online_outbox(id,property_id,booking_id,body,kind,status,based_on,actor,period,reserved_micro)values(gen_random_uuid(),p_property,bid,'','ai','generating',mid,p_data->>'actor',v_period,v_res)returning * into d;
  update omg_private.ai_wallets set balance_micro=balance_micro-v_res where property_id=p_property;
  update omg_private.ai_usage_month set reserved_micro=reserved_micro+v_res where property_id=p_property and month=v_period;
  return jsonb_build_object('id',d.id,'data',dataset,'history',history,'prompt',s.prompt,'support_policy',s.support_policy,'has_attachment',x->>'attachment_name' is not null,'alert_rules',jsonb_build_object('handoff',s.handoff_config,'emergency',s.emergency_config));
 elsif p_action='draft_finish' then
  select * into d from omg_private.online_outbox where property_id=p_property and id=(p_data->>'id')::uuid for update;
  if not found or d.status<>'generating' then return jsonb_build_object('skip',true);end if;
  it:=greatest(0,coalesce((p_data->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((p_data->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((p_data->>'cached_tokens')::bigint,0)));wt:=least(it-ct,greatest(0,coalesce((p_data->>'cache_write_tokens')::bigint,0)));
  v_cost:=least(d.reserved_micro,case when coalesce((p_data->>'estimated')::boolean,false) then d.reserved_micro else ceil((it-ct-wt)*0.10+ct*0.01+wt*0.125+ot*0.50)::bigint end);
  perform 1 from omg_private.ai_wallets where property_id=p_property for update;
  update omg_private.ai_wallets set balance_micro=balance_micro+d.reserved_micro-v_cost,updated_at=now() where property_id=p_property;
  update omg_private.ai_usage_month set reserved_micro=greatest(0,reserved_micro-d.reserved_micro),used_micro=used_micro+v_cost,responses=responses+1,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=p_property and month=d.period;
  update omg_private.online_outbox set body=coalesce(p_data->>'reply',''),status=case when nullif(p_data->>'reply','') is null then 'failed' else 'draft' end,result=p_data-'id',error=p_data->>'error',reserved_micro=0,charged_micro=v_cost,updated_at=now() where id=d.id;
 elsif p_action='draft_pending' then
  return coalesce((select jsonb_agg(to_jsonb(x)) from(select m.booking_id from omg_private.online_messages m where m.property_id=p_property and m.source='guest' and m.created_at>now()-interval '1 day' and not exists(select 1 from omg_private.online_outbox o where o.property_id=p_property and o.based_on=m.id and o.kind='ai') group by m.booking_id limit 3)x),'[]');
 elsif p_action='push_pending' then
  return coalesce((select jsonb_agg(notice_id) from omg_private.online_messages where property_id=p_property and notice_id is not null and created_at>now()-interval '5 minutes'),'[]');
 else raise exception 'invalid_action';end if;
 return jsonb_build_object('ok',true);
end$$;
create function public.online_owner(p_token uuid,p_action text,p_data jsonb default '{}')returns jsonb language sql security invoker set search_path='' as $$select omg_private.online_owner(p_token,p_action,p_data)$$;
create function public.online_internal(p_action text,p_property uuid default null,p_data jsonb default '{}')returns jsonb language sql security invoker set search_path='' as $$select omg_private.online_internal(p_action,p_property,p_data)$$;
revoke all on function public.online_owner(uuid,text,jsonb),public.online_internal(text,uuid,jsonb),omg_private.online_owner(uuid,text,jsonb),omg_private.online_internal(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.online_owner(uuid,text,jsonb),public.online_internal(text,uuid,jsonb),omg_private.online_owner(uuid,text,jsonb),omg_private.online_internal(text,uuid,jsonb) to service_role;
create function public.get_online_push_dispatch(p_message_id uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare m record;topics jsonb;modes jsonb;begin
 select msg.*,p.management_number into m from public.property_messages msg join public.properties p on p.id=msg.property_id where msg.id=p_message_id and msg.source='beds24';
 if not found then return jsonb_build_object('ok',false);end if;
 select coalesce(jsonb_agg('property_'||m.management_number||'_owner_'||r.owner_id),'[]'),coalesce(jsonb_object_agg('property_'||m.management_number||'_owner_'||r.owner_id,'normal'),'{}') into topics,modes from public.property_message_recipients r where r.message_id=m.id and r.recipient_type='owner';
 return jsonb_build_object('ok',true,'message_id',m.id,'message',regexp_replace(m.message,'^\[OMS-ONLINE:[0-9]+\]\s*',''),'recipient_topics',topics,'recipient_modes',modes,'route','online.html#thread/'||(select booking_id from omg_private.online_messages where notice_id=m.id limit 1));
end$$;
revoke all on function public.get_online_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_online_push_dispatch(uuid) to service_role;
-- Queue survives function restarts. The existing worker secret is never returned to a client.
select cron.schedule('oms-beds24-online-worker','* * * * *',$cron$
 select net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/beds24/worker',headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='oms_guest_ai_worker_secret')),body:='{}'::jsonb,timeout_milliseconds:=1000)
$cron$);
