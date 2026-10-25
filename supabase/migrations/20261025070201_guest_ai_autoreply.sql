-- Tenant-scoped guest AI. All privileged RPCs are service-role only.
create table omg_private.ai_provider(singleton boolean primary key default true check(singleton),vault_id uuid,key_suffix text,enabled boolean not null default true,updated_at timestamptz not null default now());
insert into omg_private.ai_provider(singleton) values(true);
create function omg_private.ai_default_prompt() returns text language sql immutable set search_path='' as $$select '당신은 이 게스트하우스의 친절한 AI 직원입니다. 관리자가 입력한 자동답변 DATA만 숙소 정보의 근거로 삼고 게스트가 사용한 언어로 답하세요. 질문의 표현이 제목과 달라도 의미로 연결하세요. 한 메시지에 위치와 체크인 등 여러 질문이 있으면 각 질문에 해당하는 DATA를 모두 찾아 자연스럽게 한 답변으로 합치세요. 확인된 질문부터 답하고 일부 질문의 정보가 없거나 서로 충돌하면 그 부분만 확인이 필요하다고 안내하고 숙소 관리자의 답변을 기다려 달라고 하세요. 객실 배정, 환불, 요금, 얼리 체크인 허용 등 DATA에 없는 약속을 만들지 마세요. 생명·신체 위험, 화재, 가스 누출, 폭력 등 긴급 상황이면 urgent로 분류하고 구체적인 이유를 적으세요. 단순 문의와 긴급 위험을 구분하세요. 즉시 위험한 경우 안전한 장소로 이동하고 현지 긴급기관에 연락하도록 짧게 안내하세요. 관리자에게 전달되었다는 말은 실제 전달 결과 없이 하지 마세요.'::text$$;
create table omg_private.ai_settings(property_id uuid primary key references public.properties(id) on delete cascade,enabled boolean not null default false,mode text not null default 'always' check(mode in('always','no_staff','schedule')),start_time time,end_time time,prompt text not null default omg_private.ai_default_prompt(),data jsonb not null default '[]',revision bigint not null default 1,updated_at timestamptz not null default now(),updated_by text,check(mode<>'schedule' or(start_time is not null and end_time is not null and start_time<>end_time)));
create table omg_private.ai_wallets(property_id uuid primary key references public.properties(id) on delete cascade,enabled boolean not null default true,balance_micro bigint not null default 0 check(balance_micro>=0),monthly_limit_micro bigint not null default 0 check(monthly_limit_micro>=0),updated_at timestamptz not null default now());
create table omg_private.ai_usage_month(property_id uuid references public.properties(id) on delete cascade,month date,used_micro bigint not null default 0 check(used_micro>=0),reserved_micro bigint not null default 0 check(reserved_micro>=0),responses bigint not null default 0,input_tokens bigint not null default 0,output_tokens bigint not null default 0,primary key(property_id,month));
create table omg_private.ai_jobs(id uuid primary key default gen_random_uuid(),message_id uuid not null unique references public.guest_chat_messages(id) on delete cascade,room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,property_id uuid not null references public.properties(id) on delete cascade,status text not null default 'pending' check(status in('pending','leased','completed','handoff','cancelled','failed')),lease_id uuid,leased_until timestamptz,period date,reserved_micro bigint not null default 0,charged_micro bigint not null default 0,input_tokens bigint not null default 0,output_tokens bigint not null default 0,cached_tokens bigint not null default 0,cache_write_tokens bigint not null default 0,model text not null default 'gpt-6-luna',provider_response_id text,reason text,estimated boolean not null default false,created_at timestamptz not null default now(),finished_at timestamptz);
create index ai_jobs_pending on omg_private.ai_jobs(created_at) where status='pending';
create unique index ai_jobs_one_per_room on omg_private.ai_jobs(room_id) where status='leased';
create index ai_jobs_property on omg_private.ai_jobs(property_id,created_at desc);
create table omg_private.ai_credit_log(id uuid primary key default gen_random_uuid(),request_id uuid not null unique,property_id uuid not null references public.properties(id) on delete cascade,user_id uuid not null,delta_micro bigint not null,note text,created_at timestamptz not null default now());
create index ai_credit_log_property on omg_private.ai_credit_log(property_id,created_at desc);
create table omg_private.ai_alerts(event_id uuid primary key references public.guest_chat_events(id) on delete cascade,room_id uuid not null references public.guest_chat_rooms(id) on delete cascade,message_id uuid,urgent boolean not null,reason text,created_at timestamptz not null default now());
create index ai_alerts_room on omg_private.ai_alerts(room_id,created_at desc);
alter table public.guest_chat_rooms add column ai_handoff boolean not null default false;
alter table public.guest_chat_messages drop constraint guest_chat_messages_sender_kind_check;
alter table public.guest_chat_messages add constraint guest_chat_messages_sender_kind_check check(sender_kind in('guest','staff','system','ai'));
alter table public.guest_chat_events drop constraint guest_chat_events_event_kind_check;
alter table public.guest_chat_events add constraint guest_chat_events_event_kind_check check(event_kind in('started','message','ai_handoff','ai_urgent'));
create function omg_private.ai_month() returns date language sql stable set search_path='' as $$select date_trunc('month',now() at time zone 'Asia/Seoul')::date$$;
create function omg_private.ai_active(p_property uuid,p_at timestamptz default now()) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select s.enabled and case s.mode when 'always' then true when 'no_staff' then not exists(select 1 from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=s.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>p_at) else case when s.start_time<s.end_time then (p_at at time zone p.timezone)::time>=s.start_time and (p_at at time zone p.timezone)::time<s.end_time else (p_at at time zone p.timezone)::time>=s.start_time or (p_at at time zone p.timezone)::time<s.end_time end end from omg_private.ai_settings s join public.properties p on p.id=s.property_id where s.property_id=p_property),false)
$$;
create function omg_private.ai_summary(p_property uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('balance',coalesce(w.balance_micro,0)/1000.0,'monthly_limit',coalesce(w.monthly_limit_micro,0)/1000.0,'used',coalesce(u.used_micro,0)/1000.0,'reserved',coalesce(u.reserved_micro,0)/1000.0,'enabled',coalesce(w.enabled,false),'responses',coalesce(u.responses,0),'month',omg_private.ai_month(),'credit_usd',0.001,'available',greatest(0,least(coalesce(w.balance_micro,0)-coalesce((select sum(j.reserved_micro) from omg_private.ai_jobs j where j.property_id=p_property and j.status='leased'),0),coalesce(w.monthly_limit_micro,0)-coalesce(u.used_micro+u.reserved_micro,0)))/1000.0) from (select p_property id)x left join omg_private.ai_wallets w on w.property_id=x.id left join omg_private.ai_usage_month u on u.property_id=x.id and u.month=omg_private.ai_month()
$$;
create function omg_private.ai_owner(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;home uuid;rows jsonb;item jsonb;v_mode text;st time;et time;begin
 a:=omg_private.guest_actor(p_token);if a is null or a->>'kind'<>'owner' then raise exception '관리자 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 insert into omg_private.ai_settings(property_id) values(home) on conflict do nothing;insert into omg_private.ai_wallets(property_id) values(home) on conflict do nothing;
 if p_action='save' then
  rows:=coalesce(p_data->'data','[]');v_mode:=coalesce(p_data->>'mode','always');st:=nullif(p_data->>'start_time','')::time;et:=nullif(p_data->>'end_time','')::time;
  if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>200 or octet_length(rows::text)>60000 then raise exception 'DATA는 200행, 총 60KB까지 입력할 수 있습니다.';end if;
  if v_mode not in('always','no_staff','schedule') or (v_mode='schedule' and(st is null or et is null or st=et)) then raise exception '사용 조건과 서로 다른 시작·종료 시간을 선택해주세요.';end if;
  if length(btrim(coalesce(p_data->>'prompt',''))) not between 1 and 8000 then raise exception '프롬프트는 1~8,000자로 입력해주세요.';end if;
  for item in select value from jsonb_array_elements(rows) loop if length(btrim(coalesce(item->>'title',''))) not between 1 and 120 or length(coalesce(item->>'answer',''))>4000 then raise exception '제목은 1~120자, 답변은 4,000자 이내로 입력해주세요.';end if;end loop;
  if coalesce((p_data->>'enabled')::boolean,false) and not exists(select 1 from jsonb_array_elements(rows)j where length(btrim(coalesce(j->>'answer','')))>0) then raise exception '자동답변 DATA를 하나 이상 입력해주세요.';end if;
  update omg_private.ai_settings set enabled=coalesce((p_data->>'enabled')::boolean,false),mode=v_mode,start_time=st,end_time=et,prompt=btrim(p_data->>'prompt'),data=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'answer',btrim(j->>'answer'))),'[]') from jsonb_array_elements(rows)j),revision=revision+1,updated_at=now(),updated_by=a->>'key' where property_id=home;
 elsif p_action<>'get' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'settings',(select to_jsonb(s) from omg_private.ai_settings s where property_id=home),'usage',omg_private.ai_summary(home),'default_prompt',omg_private.ai_default_prompt(),'provider_ready',exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null),'qr_enabled',exists(select 1 from public.guest_support_config where property_id=home and enabled and chat_enabled),'timezone',(select timezone from public.properties where id=home),'history',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select created_at,status,charged_micro/1000.0 credits,reason,estimated from omg_private.ai_jobs where property_id=home order by created_at desc limit 30)x));
end$$;
create function omg_private.ai_platform(p_user uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare secretid uuid;prop uuid;delta bigint;cap bigint;request uuid;old omg_private.ai_credit_log%rowtype;begin
 if not exists(select 1 from public.platform_administrators where user_id=p_user) then raise exception '운영센터 권한이 필요합니다.';end if;
 if p_action='connect' then
  if (coalesce(p_data->>'key','') !~ '^sk-[A-Za-z0-9_-]+$' or length(p_data->>'key') not between 23 and 503) then raise exception 'API 키를 확인해주세요.';end if;
  select vault_id into secretid from omg_private.ai_provider where singleton for update;
  if secretid is null then select vault.create_secret(p_data->>'key','oms_guest_ai_api_key','OMS guest AI provider') into secretid;else perform vault.update_secret(secretid,p_data->>'key');end if;
  update omg_private.ai_provider set vault_id=secretid,key_suffix=right(p_data->>'key',4),updated_at=now() where singleton;
 elsif p_action='provider' then update omg_private.ai_provider set enabled=coalesce((p_data->>'enabled')::boolean,false),updated_at=now() where singleton;
 elsif p_action='wallet' then
  prop:=(p_data->>'property_id')::uuid;request:=(p_data->>'request_id')::uuid;delta:=round((p_data->>'delta')::numeric*1000);cap:=round((p_data->>'monthly_limit')::numeric*1000);
  if request is null or delta is null or abs(delta)>100000000000 or cap is null or cap not between 0 and 100000000000 then raise exception '크레딧과 월 한도를 확인해주세요.';end if;
  perform pg_advisory_xact_lock(hashtextextended(request::text,91));select * into old from omg_private.ai_credit_log where request_id=request;
  if found then if old.property_id<>prop or old.user_id<>p_user or old.delta_micro<>delta then raise exception '이미 처리한 요청입니다.';end if;
  else
   insert into omg_private.ai_wallets(property_id) values(prop) on conflict do nothing;
   perform 1 from omg_private.ai_wallets where property_id=prop for update;
   if (select balance_micro+delta from omg_private.ai_wallets where property_id=prop)<coalesce((select sum(reserved_micro) from omg_private.ai_jobs where property_id=prop and status='leased'),0) then raise exception '잔액 또는 처리 중인 예약 크레딧보다 많이 차감할 수 없습니다.';end if;
   update omg_private.ai_wallets set balance_micro=balance_micro+delta,monthly_limit_micro=cap,enabled=coalesce((p_data->>'enabled')::boolean,false),updated_at=now() where property_id=prop;
   insert into omg_private.ai_credit_log(request_id,property_id,user_id,delta_micro,note)values(request,prop,p_user,delta,left(p_data->>'note',300));
  end if;
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'provider',(select jsonb_build_object('ready',vault_id is not null,'suffix',key_suffix,'enabled',enabled,'model','gpt-6-luna') from omg_private.ai_provider),'properties',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'number',p.management_number,'usage',omg_private.ai_summary(p.id),'ai_enabled',coalesce(s.enabled,false)) order by p.name),'[]') from public.properties p left join omg_private.ai_settings s on s.property_id=p.id),'adjustments',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from(select l.created_at,p.name,l.delta_micro/1000.0 credits,l.note from omg_private.ai_credit_log l join public.properties p on p.id=l.property_id order by l.created_at desc limit 60)x));
end$$;
create function omg_private.ai_credentials() returns jsonb language sql security definer set search_path='' as $$select jsonb_build_object('enabled',p.enabled,'key',s.decrypted_secret) from omg_private.ai_provider p left join vault.decrypted_secrets s on s.id=p.vault_id$$;
create function omg_private.ai_alert(p_room uuid,p_message uuid,p_urgent boolean,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare ev uuid;begin
 perform pg_advisory_xact_lock(hashtextextended(p_room::text,71));
 update public.guest_chat_rooms set ai_handoff=true,updated_at=now() where id=p_room;
 select event_id into ev from omg_private.ai_alerts where room_id=p_room and urgent=p_urgent and created_at>now()-interval '60 seconds' order by created_at desc limit 1;
 if ev is null then
  insert into public.guest_chat_events(room_id,event_kind)values(p_room,case when p_urgent then 'ai_urgent' else 'ai_handoff' end) returning id into ev;
  insert into omg_private.ai_alerts(event_id,room_id,message_id,urgent,reason)values(ev,p_room,p_message,p_urgent,left(p_reason,500));
 end if;return ev;
end$$;
create function omg_private.ai_room_action(p_action text,p_data jsonb,p_token uuid,p_guest uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;r public.guest_chat_rooms%rowtype;ev uuid;begin
 a:=omg_private.guest_actor(p_token);select * into r from public.guest_chat_rooms where id=(p_data->>'room_id')::uuid for update;
 if not found then raise exception '대화를 확인해주세요.';end if;
 if a is not null then if not omg_private.guest_can_access((a->>'property_id')::uuid,r.property_id) then raise exception '대화 접근 권한이 없습니다.';end if;
 elsif p_guest is null or r.expires_at<=now() or not(r.token_hash=omg_private.token_hash(p_guest) or exists(select 1 from public.guest_email_sessions s where s.room_id=r.id and s.token_hash=omg_private.token_hash(p_guest) and s.expires_at>now())) then raise exception '대화 이용 시간이 만료되었습니다.';end if;
 if p_action='ai_resume' then
  if a is null or (r.assigned_key is not null and r.assigned_key<>a->>'key' and a->>'kind'<>'owner') then raise exception '담당 직원 또는 관리자만 AI를 재개할 수 있습니다.';end if;
  update public.guest_chat_rooms set ai_handoff=false,assigned_key=null,assigned_name=null,assigned_at=null where id=r.id;
 elsif p_action in('ai_human','ai_urgent') then
  if r.status<>'open' then raise exception '종료된 대화입니다.';end if;
  perform omg_private.guest_limit('ai-help:'||r.id,3,60);
  ev:=omg_private.ai_alert(r.id,(select id from public.guest_chat_messages where room_id=r.id and sender_kind='guest' order by seq desc limit 1),p_action='ai_urgent',case when p_action='ai_urgent' then '게스트가 긴급 호출을 요청했습니다.' else '게스트가 직원 연결을 요청했습니다.' end);
 else raise exception '지원하지 않는 요청입니다.';end if;
 return jsonb_build_object('ok',true,'event_id',ev);
end$$;
create function omg_private.ai_enqueue() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.sender_kind='guest' and exists(select 1 from public.guest_chat_rooms r where r.id=new.room_id and r.status='open' and r.assigned_key is null and not r.ai_handoff and omg_private.ai_active(r.property_id)) then
  insert into omg_private.ai_jobs(message_id,room_id,property_id)select new.id,r.id,r.property_id from public.guest_chat_rooms r where r.id=new.room_id on conflict do nothing;
 end if;return new;
end$$;
create trigger guest_ai_enqueue after insert on public.guest_chat_messages for each row execute function omg_private.ai_enqueue();
-- Reservation and settlement are atomic per tenant; a lease never repeats a paid call.
create function omg_private.ai_finish(p_id uuid,p_lease uuid,p_result jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare j omg_private.ai_jobs%rowtype;r public.guest_chat_rooms%rowtype;cost bigint;it bigint;ot bigint;ct bigint;wt bigint;ev uuid;disposition text;txt text;why text;v_estimated boolean;begin
 select * into j from omg_private.ai_jobs where id=p_id;if not found then return jsonb_build_object('ok',false);end if;
 select * into r from public.guest_chat_rooms where id=j.room_id for update;
 select * into j from omg_private.ai_jobs where id=p_id for update;
 if j.status<>'leased' or j.lease_id is distinct from p_lease then return jsonb_build_object('ok',true,'already_finished',true);end if;
 perform 1 from omg_private.ai_wallets where property_id=j.property_id for update;
 v_estimated:=coalesce((p_result->>'estimated')::boolean,false);it:=greatest(0,coalesce((p_result->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((p_result->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((p_result->>'cached_tokens')::bigint,0)));
 wt:=least(it-ct,greatest(0,coalesce((p_result->>'cache_write_tokens')::bigint,0)));
 cost:=case when v_estimated then j.reserved_micro else ceil((it-ct-wt)*0.10+ct*0.01+wt*0.125+ot*0.50)::bigint end;
 -- The documented rate and a byte-count upper bound reserve enough for this model.
 -- If a provider violates that bound, debit only the reserved amount and flag review.
 if cost>j.reserved_micro then cost:=j.reserved_micro;v_estimated:=true;end if;
 update omg_private.ai_wallets set balance_micro=balance_micro-cost,updated_at=now() where property_id=j.property_id;
 update omg_private.ai_usage_month set reserved_micro=reserved_micro-j.reserved_micro,used_micro=used_micro+cost,responses=responses+case when cost>0 then 1 else 0 end,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=j.property_id and month=j.period;
 disposition:=coalesce(p_result->>'disposition','handoff');why:=left(coalesce(p_result->>'reason','직원 확인이 필요합니다.'),500);txt:=left(btrim(coalesce(p_result->>'reply','')),4000);
 if r.assigned_key is not null or r.ai_handoff or r.status<>'open' or r.expires_at<=now() or not omg_private.ai_active(r.property_id) then
  update omg_private.ai_jobs set status='cancelled',reason='직원 대응 또는 자동답변 조건 변경',charged_micro=cost,input_tokens=it,output_tokens=ot,cached_tokens=ct,cache_write_tokens=wt,estimated=v_estimated,provider_response_id=p_result->>'response_id',finished_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'discarded',true);
 end if;
 if disposition not in('answer','handoff','urgent') or txt='' then disposition:='handoff';txt:='정확한 안내를 위해 직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / A staff member needs to check this. Please wait for their reply.';end if;
 if disposition<>'answer' then ev:=omg_private.ai_alert(r.id,j.message_id,disposition='urgent',why);end if;
 insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values(r.id,j.id,'ai:oms','OMS AI','ai',txt) on conflict(room_id,sender_key,client_id) do nothing;
 update public.guest_chat_rooms set updated_at=now() where id=r.id;
 update omg_private.ai_jobs set status=case when disposition='answer' then 'completed' else 'handoff' end,reason=why,charged_micro=cost,input_tokens=it,output_tokens=ot,cached_tokens=ct,cache_write_tokens=wt,estimated=v_estimated,provider_response_id=p_result->>'response_id',finished_at=now() where id=j.id;
 return jsonb_build_object('ok',true,'event_id',ev);
end$$;
create function omg_private.ai_claim() returns jsonb language plpgsql security definer set search_path='' as $$
declare j omg_private.ai_jobs%rowtype;r public.guest_chat_rooms%rowtype;s omg_private.ai_settings%rowtype;w omg_private.ai_wallets%rowtype;history jsonb;dataset jsonb;reservation bigint;used bigint;reserved bigint;totalreserved bigint;v_month date;ev uuid;begin
 -- Expired leases are settled once, conservatively; never make an ambiguous paid request twice.
 select * into j from omg_private.ai_jobs where status='leased' and leased_until<now() order by leased_until limit 1;
 if found then return omg_private.ai_finish(j.id,j.lease_id,jsonb_build_object('estimated',true,'disposition','handoff','reason','AI 응답 확인 시간 초과 · 예약 비용 추정 정산','reply','직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / Please wait for a staff reply.'))||jsonb_build_object('skip',true);end if;
 select q.* into j from omg_private.ai_jobs q where q.status='pending' and not exists(select 1 from omg_private.ai_jobs x where x.room_id=q.room_id and x.status='leased') order by q.created_at limit 1;
 if not found then return jsonb_build_object('ok',true,'empty',true);end if;
 select * into r from public.guest_chat_rooms where id=j.room_id for update skip locked;
 if not found then return jsonb_build_object('ok',true,'empty',true);end if;
 select * into j from omg_private.ai_jobs where id=j.id for update;
 if j.status<>'pending' or exists(select 1 from omg_private.ai_jobs x where x.room_id=r.id and x.status='leased') then return jsonb_build_object('ok',true,'skip',true);end if;
 if r.status<>'open' or r.expires_at<=now() or r.assigned_key is not null or r.ai_handoff or not omg_private.ai_active(r.property_id) then
  update omg_private.ai_jobs set status='cancelled',reason='자동답변 조건 변경',finished_at=now() where id=j.id;
  if r.status='open' and not r.ai_handoff and r.assigned_key is null then ev:=omg_private.ai_alert(r.id,j.message_id,false,'자동답변 사용 조건이 변경되어 직원 확인이 필요합니다.');end if;
  return jsonb_build_object('ok',true,'skip',true,'event_id',ev);
 end if;
 select * into s from omg_private.ai_settings where property_id=r.property_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.n::text,'title',x.v->>'title','answer',x.v->>'answer')),'[]') into dataset from jsonb_array_elements(s.data) with ordinality x(v,n) where btrim(coalesce(x.v->>'answer',''))<>'';
 select coalesce(jsonb_agg(jsonb_build_object('role',case when x.sender_kind='guest' then 'user' else 'assistant' end,'content',left(x.body,2000)) order by x.seq),'[]') into history from(select m.seq,m.body,m.sender_kind from public.guest_chat_messages m where m.room_id=r.id and m.seq<=(select seq from public.guest_chat_messages where id=j.message_id) and m.sender_kind in('guest','ai','staff') order by m.seq desc limit 12)x;
 -- Keep the latest question whole, including multiple questions in the same message.
 history:=jsonb_set(history,array[(jsonb_array_length(history)-1)::text,'content'],to_jsonb((select body from public.guest_chat_messages where id=j.message_id)));
 reservation:=ceil((octet_length(s.prompt)+octet_length(dataset::text)+octet_length(history::text)+16000)*0.125+2048*0.50)::bigint;
 insert into omg_private.ai_wallets(property_id)values(r.property_id)on conflict do nothing;
 select * into w from omg_private.ai_wallets where property_id=r.property_id for update;
 v_month:=omg_private.ai_month();insert into omg_private.ai_usage_month(property_id,month)values(r.property_id,v_month)on conflict do nothing;
 select u.used_micro,u.reserved_micro into used,reserved from omg_private.ai_usage_month u where u.property_id=r.property_id and u.month=v_month;
 select coalesce(sum(reserved_micro),0) into totalreserved from omg_private.ai_jobs where property_id=r.property_id and status='leased';
 if not w.enabled or w.balance_micro-totalreserved<reservation or w.monthly_limit_micro-used-reserved<reservation or not exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null) or dataset='[]'::jsonb or j.created_at<now()-interval '5 minutes' then
  ev:=omg_private.ai_alert(r.id,j.message_id,false,'AI 연결·사용 한도 또는 응답 대기 상태를 확인해주세요.');
  insert into public.guest_chat_messages(room_id,client_id,sender_key,sender_name,sender_kind,body)values(r.id,j.id,'ai:oms','OMS AI','ai','현재 자동 안내가 어려워 직원 확인이 필요합니다. 숙소 관리자의 답변을 기다려주세요. / Please wait for a staff reply.')on conflict do nothing;
  update omg_private.ai_jobs set status='handoff',reason='연결 미완료·한도 부족·대기 시간 초과',finished_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'skip',true,'event_id',ev);
 end if;
 update omg_private.ai_usage_month set reserved_micro=reserved_micro+reservation where property_id=r.property_id and ai_usage_month.month=v_month;
 update omg_private.ai_jobs set status='leased',lease_id=gen_random_uuid(),leased_until=now()+interval '90 seconds',period=v_month,reserved_micro=reservation where id=j.id returning * into j;
 return jsonb_build_object('ok',true,'id',j.id,'lease_id',j.lease_id,'prompt',s.prompt,'data',dataset,'history',history,'has_attachment',(select asset_id is not null from public.guest_chat_messages where id=j.message_id),'reserved_micro',reservation);
end$$;

CREATE OR REPLACE FUNCTION public.guest_support_rpc(p_action text, p_data jsonb DEFAULT '{}'::jsonb, p_token uuid DEFAULT NULL::uuid, p_guest_token uuid DEFAULT NULL::uuid, p_ip_hash text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;home uuid;prop uuid;room public.guest_chat_rooms%rowtype;cfg public.guest_support_config%rowtype;
 item jsonb;v_items jsonb;result jsonb;msgs jsonb;assets jsonb;roomid uuid;assetid uuid;eventid uuid;msgid uuid;
 guesttoken uuid;actor text;displayname text;kind text;body text;client uuid;ci date;co date;pref jsonb;target text;
 props uuid[];days integer[];st time;et time;seqid bigint;cursorid bigint;hasmore boolean;email_value text;room_unknown boolean;
begin
 if p_action in('ai_human','ai_urgent','ai_resume') then return omg_private.ai_room_action(p_action,p_data,p_token,p_guest_token);end if;
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
 email_value:=nullif(lower(btrim(p_data->>'email')),'');
 room_unknown:=coalesce((p_data->>'room_unknown')::boolean,false);
 if email_value is not null and (length(email_value)>254 or email_value !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception '이메일 주소를 확인해주세요.';end if;
 if coalesce(p_data->>'entry_version','1')='2' then
 if email_value is null then raise exception '이메일을 입력해주세요.';end if;
 if not room_unknown and nullif(btrim(p_data->>'room_number'),'') is null then raise exception '객실명/호수를 입력하거나 아직 모릅니다를 선택해주세요.';end if;
 end if;
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
 insert into public.guest_chat_rooms(property_id,guest_name,check_in,check_out,room_number,email,room_unknown,token_hash,expires_at,ip_hash)
 values(cfg.property_id,displayname,ci,co,case when room_unknown then null else nullif(btrim(p_data->>'room_number'),'') end,email_value,room_unknown,omg_private.token_hash(guesttoken),
 least((co+2)::timestamp at time zone (select timezone from public.properties where id=cfg.property_id),now()+interval '60 days'),p_ip_hash) returning * into room;
 insert into public.guest_chat_events(room_id,event_kind) values(room.id,'started') returning id into eventid;
 return jsonb_build_object('ok',true,'room_id',room.id,'event_id',eventid);
 end if;
 a:=omg_private.guest_actor(p_token);home:=(a->>'property_id')::uuid;
 if a is not null then actor:=a->>'key';displayname:=a->>'name';kind:='staff';
 elsif p_guest_token is not null then
 select * into room from public.guest_chat_rooms where (token_hash=omg_private.token_hash(p_guest_token)
 or id in(select es.room_id from public.guest_email_sessions es where es.token_hash=omg_private.token_hash(p_guest_token) and es.expires_at>now())) and expires_at>now();
 if not found then raise exception '대화 이용 시간이 만료되었습니다. QR로 다시 입장해주세요.';end if;
 actor:='guest:'||room.id;displayname:=room.guest_name;kind:='guest';
 else raise exception '로그인이 필요합니다.';end if;

 if p_action in('settings','save_settings','save_preferences') then
 if a->>'kind'<>'owner' or a is null then raise exception '관리자만 설정할 수 있습니다.';end if;
 insert into public.guest_support_config(property_id) values(home) on conflict do nothing;
 if p_action='save_settings' then
 v_items:=coalesce(p_data->'items','[]');
 if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)>9 then raise exception '안내 항목은 9개까지 등록할 수 있습니다.';end if;
 for item in select value from jsonb_array_elements(v_items) loop
 if nullif(item->>'icon','') is not null and item->>'icon' !~ '^(0[1-9]|[1-4][0-9]|50)$' then raise exception '이모지를 다시 선택해주세요.';end if;
 if length(btrim(coalesce(item->>'title',''))) not between 1 and 60 then raise exception '항목 제목을 입력해주세요.';end if;
 if not exists(select 1 from public.guest_support_assets x where x.id=(item->>'asset_id')::uuid and x.property_id=home and x.room_id is null and x.ready) then raise exception '안내 사진 또는 PDF를 첨부해주세요.';end if;
 end loop;
 update public.guest_support_config set enabled=coalesce((p_data->>'enabled')::boolean,false),chat_enabled=coalesce((p_data->>'chat_enabled')::boolean,false),
 items=(select coalesce(jsonb_agg(jsonb_build_object('title',btrim(j->>'title'),'asset_id',j->>'asset_id','icon',nullif(j->>'icon',''))),'[]') from jsonb_array_elements(v_items)j),updated_at=now() where property_id=home;
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
 (select min(g.created_at) from public.guest_chat_messages g where g.room_id=r.id and g.sender_kind='guest' and g.seq>coalesce((select max(s.seq) from public.guest_chat_messages s where s.room_id=r.id and (s.sender_kind='staff' or (s.sender_kind='ai' and not r.ai_handoff))),0)) unanswered_since,
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
 select * into room from public.guest_chat_rooms where id=roomid for update;
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
 return jsonb_build_object('ok',true,'message_id',msgid,'event_id',eventid,'ai_queued',exists(select 1 from omg_private.ai_jobs where message_id=msgid and status='pending'));
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
 return jsonb_build_object('ok',true,'messages',msgs,'assets',assets,'room',jsonb_build_object('id',room.id,'guest_name',room.guest_name,'check_in',room.check_in,'check_out',room.check_out,'room_number',room.room_number,'email',case when kind='staff' then room.email else null end,'room_unknown',room.room_unknown,'status',room.status,'unanswered_since',(select min(g.created_at) from public.guest_chat_messages g where g.room_id=roomid and g.sender_kind='guest' and g.seq>coalesce((select max(s.seq) from public.guest_chat_messages s where s.room_id=roomid and (s.sender_kind='staff' or(s.sender_kind='ai' and not room.ai_handoff))),0)),'property_name',(select name from public.properties where id=room.property_id),
 'assigned_name',case when kind='guest' then case when room.assigned_key is not null then '직원' end else room.assigned_name end,
 'assigned_key',case when kind='guest' then null else room.assigned_key end,'chat_enabled',coalesce(cfg.enabled and cfg.chat_enabled,false),'ai_handoff',room.ai_handoff,'ai_active',omg_private.ai_active(room.property_id) and room.assigned_key is null and not room.ai_handoff),
 'actor_key',case when kind='guest' then 'guest:'||roomid else actor end);
 elsif p_action='retry_events' then
 perform omg_private.guest_limit('retry:'||actor,5,60);
 return jsonb_build_object('ok',true,'event_ids',(select coalesce(jsonb_agg(id),'[]') from(select e.id from public.guest_chat_events e where e.room_id=roomid and not dispatch_finished and e.created_at>now()-interval '5 minutes' order by created_at limit 10)x));
 end if;
 raise exception '지원하지 않는 요청입니다.';
end$function$

;

CREATE OR REPLACE FUNCTION public.get_guest_chat_dispatch(p_event_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ev public.guest_chat_events%rowtype;r public.guest_chat_rooms%rowtype;topics jsonb;deadlines jsonb;modes jsonb;alert omg_private.ai_alerts%rowtype;begin
 select * into ev from public.guest_chat_events where id=p_event_id;
 if not found then return jsonb_build_object('ok',false,'code','not_found');end if;
 select * into r from public.guest_chat_rooms where id=ev.room_id;
 if ev.created_at<now()-interval '5 minutes' or not exists(select 1 from public.guest_support_config where property_id=r.property_id and enabled and chat_enabled) then
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb,'expired',true);end if;

 -- AI handles ordinary questions silently; escalation has its own durable event.
 if ev.event_kind='message' and exists(select 1 from omg_private.ai_jobs where message_id=ev.message_id and status in('pending','leased','completed','handoff')) then
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics','[]'::jsonb);end if;
 select * into alert from omg_private.ai_alerts where event_id=ev.id;
 if found then
  select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,case when alert.urgent then 'urgent' else 'normal' end),'{}') into topics,modes from(
   select 'property_'||p.management_number||'_owner_'||o.id topic from public.owners o join public.properties p on p.id=o.property_id where o.property_id=r.property_id and o.active
   union select 'property_'||p.management_number||'_employee_'||e.id from public.work_sessions w join public.employees e on e.id=w.employee_id join public.properties p on p.id=w.property_id where w.property_id=r.property_id and e.active and w.status='working' and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now()
  )x;
  return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_modes',modes,'message_type','guest_chat','valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,'priority',case when alert.urgent then 'urgent' else 'normal' end,'sender_label',case when alert.urgent then '긴급 · ' else '직원 확인 · ' end||r.guest_name||' · '||coalesce(r.room_number,'객실 미정'),'message',alert.reason||E'\n'||coalesce((select left(body,700) from public.guest_chat_messages where id=alert.message_id),''));
 end if;
 select coalesce(jsonb_agg(x.topic),'[]'),coalesce(jsonb_object_agg(x.topic,x.valid_until),'{}'),
  coalesce(jsonb_object_agg(x.topic,x.alert_mode),'{}') into topics,deadlines,modes from(
  select distinct on(c.topic)c.topic,c.alert_mode,c.valid_until from(
   select 'property_'||p.management_number||'_'||replace(n.actor_key,':','_') topic,s->>'alert_mode' alert_mode,
    ((extract(epoch from least(ev.created_at+interval '5 minutes',
     (case when nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time' then (local.t::date+1)::timestamp
      when (s->>'start_time')::time>(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time then (local.t::date+1)+(s->>'end_time')::time
      else local.t::date+(s->>'end_time')::time end) at time zone p.timezone))*1000)::bigint)::text valid_until,
    case s->>'alert_mode' when 'urgent' then 4 when 'strong' then 3 when 'normal' then 2 else 1 end strength
   from public.guest_chat_alert_preferences n join public.properties p on p.id=n.home_property_id
   cross join lateral jsonb_array_elements(n.schedules)s
   cross join lateral(select now() at time zone p.timezone t)local
   where coalesce((s->>'enabled')::boolean,false)
   and r.property_id=any(array(select value::uuid from jsonb_array_elements_text(s->'property_ids')))
   and omg_private.guest_can_access(n.home_property_id,r.property_id)
   and (case when nullif(s->>'start_time','') is not null and (s->>'end_time')::time<(s->>'start_time')::time and local.t::time<(s->>'end_time')::time
      then extract(dow from local.t-interval '1 day')::int else extract(dow from local.t)::int end)
      =any(array(select value::integer from jsonb_array_elements_text(s->'days')))
   and (nullif(s->>'start_time','') is null or s->>'start_time'=s->>'end_time'
      or ((s->>'start_time')::time<(s->>'end_time')::time and local.t::time>=(s->>'start_time')::time and local.t::time<(s->>'end_time')::time)
      or ((s->>'start_time')::time>(s->>'end_time')::time and (local.t::time>=(s->>'start_time')::time or local.t::time<(s->>'end_time')::time)))
   and (exists(select 1 from public.work_sessions ws join public.employees e on e.id=ws.employee_id where 'employee:'||e.id=n.actor_key and e.active and ws.status='working' and ws.token_expires_at>now())
    or exists(select 1 from public.owner_sessions os join public.owners o on o.id=os.owner_id where 'owner:'||o.id=n.actor_key and o.active and os.token_expires_at>now()))
  )c order by c.topic,c.strength desc,c.valid_until desc
 )x;
 return jsonb_build_object('ok',true,'message_id',ev.id,'room_id',r.id,'recipient_topics',topics,'recipient_deadlines',deadlines,'recipient_modes',modes,'message_type','guest_chat',
  'valid_until',((extract(epoch from ev.created_at+interval '5 minutes')*1000)::bigint)::text,
  'priority',case when ev.event_kind='started' then 'normal' else 'urgent' end,'sender_label',r.guest_name,
  'message',case when ev.event_kind='started' then '현장 게스트와의 대화가 시작되었습니다.' else coalesce((select case when nullif(btrim(m.body),'') is not null then left(m.body,1000) when m.asset_id is not null then '사진을 보냈습니다.' else '새 메시지가 도착했습니다.' end from public.guest_chat_messages m where m.id=ev.message_id),'새 메시지가 도착했습니다.') end);
end$function$

;
-- Persistent fallback worker authentication never leaves the server.
do $$begin if not exists(select 1 from vault.secrets where name='oms_guest_ai_worker_secret') then perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'oms_guest_ai_worker_secret','OMS AI queue worker');end if;end$$;
create function omg_private.ai_verify_worker(p_secret text) returns boolean language sql security definer set search_path='' as $$select coalesce(length(p_secret)=64 and exists(select 1 from vault.decrypted_secrets where name='oms_guest_ai_worker_secret' and extensions.digest(convert_to(decrypted_secret,'UTF8'),'sha256')=extensions.digest(convert_to(p_secret,'UTF8'),'sha256')),false)$$;
-- Public wrappers are intentionally executable by the authenticated server only.
create function public.guest_ai_owner(p_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.ai_owner(p_token,p_action,p_data)$$;
create function public.guest_ai_platform(p_user uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.ai_platform(p_user,p_action,p_data)$$;
create function public.guest_ai_claim() returns jsonb language sql security invoker set search_path='' as $$select omg_private.ai_claim()$$;
create function public.guest_ai_finish(p_id uuid,p_lease uuid,p_result jsonb) returns jsonb language sql security invoker set search_path='' as $$select omg_private.ai_finish(p_id,p_lease,p_result)$$;
create function public.guest_ai_credentials() returns jsonb language sql security invoker set search_path='' as $$select omg_private.ai_credentials()$$;
create function public.guest_ai_verify_worker(p_secret text) returns boolean language sql security invoker set search_path='' as $$select omg_private.ai_verify_worker(p_secret)$$;
create function public.guest_ai_pending_alerts() returns jsonb language sql security definer set search_path='' as $$select coalesce(jsonb_agg(id),'[]') from(select e.id from public.guest_chat_events e join omg_private.ai_alerts a on a.event_id=e.id where not e.dispatch_finished and e.created_at>now()-interval '5 minutes' order by e.created_at limit 30)x$$;
do $$declare t record;begin
 for t in select tablename from pg_tables where schemaname='omg_private' and tablename like 'ai_%' loop execute format('alter table omg_private.%I enable row level security',t.tablename);execute format('revoke all on table omg_private.%I from public,anon,authenticated',t.tablename);end loop;
 for t in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where(n.nspname='omg_private' and p.proname like 'ai_%')or(n.nspname='public' and p.proname like 'guest_ai_%') loop execute format('revoke all on function %s from public,anon,authenticated',t.signature);execute format('grant execute on function %s to service_role',t.signature);end loop;
end$$;
grant usage on schema omg_private to service_role;
select cron.schedule('oms-guest-ai-worker','* * * * *',$job$
 select net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/guest-ai/worker',headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='oms_guest_ai_worker_secret')),body:='{}'::jsonb,timeout_milliseconds:=1000)
 where exists(select 1 from omg_private.ai_jobs where status in('pending','leased')) or exists(select 1 from public.guest_chat_events e join omg_private.ai_alerts a on a.event_id=e.id where not e.dispatch_finished and e.created_at>now()-interval '5 minutes');
$job$);
