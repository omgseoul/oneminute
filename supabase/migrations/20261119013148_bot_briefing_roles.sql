-- Roles are operational labels, never login/authorization roles.
alter table public.employees add column if not exists duty_roles text[] not null default '{}';
alter table public.employees add constraint employee_duty_roles_valid check(duty_roles <@ array['reservation','onsite','cleaning']::text[] and array_position(duty_roles,null) is null);

create or replace function omg_private.employee_duty_roles(p_token uuid,p_property uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare eid uuid;roles text[];begin
 if not coalesce(omg_private.can_manage_shared_property(p_token,p_property,'account_settings'),false) then raise exception '계정관리 권한이 없습니다.';end if;
 if p_action='save' then
  eid:=(p_data->>'employee_id')::uuid;
  if not exists(select 1 from public.employees where id=eid and property_id=p_property and role<>'owner') then raise exception '근무자를 확인해주세요.';end if;
  if jsonb_typeof(p_data->'roles') is distinct from 'array' then raise exception '역할을 확인해주세요.';end if;
  select coalesce(array_agg(distinct v),'{}') into roles from jsonb_array_elements_text(p_data->'roles')v;
  if not roles <@ array['reservation','onsite','cleaning']::text[] or array_position(roles,null) is not null then raise exception '역할을 확인해주세요.';end if;
  update public.employees set duty_roles=roles where id=eid;
 elsif p_action<>'get' then raise exception '잘못된 요청입니다.';end if;
 return jsonb_build_object('ok',true,'employees',(select coalesce(jsonb_agg(jsonb_build_object('employee_id',id,'roles',duty_roles)),'[]') from public.employees where property_id=p_property and role<>'owner'));
end$$;
create or replace function public.employee_duty_roles(p_access_token uuid,p_property_id uuid,p_action text default 'get',p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.employee_duty_roles(p_access_token,p_property_id,p_action,p_data)$$;
revoke all on function omg_private.employee_duty_roles(uuid,uuid,text,jsonb),public.employee_duty_roles(uuid,uuid,text,jsonb) from public;
grant execute on function omg_private.employee_duty_roles(uuid,uuid,text,jsonb),public.employee_duty_roles(uuid,uuid,text,jsonb) to anon,authenticated,service_role;

create or replace function omg_private.briefing_default_prompt() returns text language sql immutable set search_path='' as $$select '설정된 기간에 새로운 게스트 메시지가 들어온 대화를 한국어로 정리해주세요. 변기 막힘, 정전·조명 고장, 문이 열리지 않음 등 빠른 조치가 필요한 이슈를 먼저 표시하고 객실번호를 반드시 포함해주세요. 객실번호가 확인되지 않으면 객실 미확인으로 표시하고 추측하지 마세요. 대화의 직원 답변까지 검토하여 해결 완료와 아직 조치가 필요한 상태를 구분해주세요. 감사 인사, 잘 머물다 갑니다 등 답변이나 조치가 필요 없는 대화는 제외해주세요. 각 항목에 문제 요약과 직원이 확인할 다음 조치를 간결하게 적어주세요. 비밀번호·도어락 코드·연락처 등 민감한 정보는 요약에 쓰지 마세요.'::text$$;
create table omg_private.briefing_settings(
 property_id uuid primary key references public.properties(id) on delete cascade,
 enabled boolean not null default false,start_kind text not null default 'time' check(start_kind in('time','checkout')),end_kind text not null default 'time' check(end_kind in('time','checkin')),
 start_time time default '19:00',end_time time default '09:00',prompt text not null default omg_private.briefing_default_prompt(),
 enabled_since timestamptz not null default now(),updated_at timestamptz not null default now(),
 check(start_kind<>'time' or start_time is not null),check(end_kind<>'time' or end_time is not null),check(char_length(prompt) between 1 and 12000)
);
create table omg_private.briefing_runs(
 id uuid primary key default gen_random_uuid(),property_id uuid not null references public.properties(id) on delete cascade,
 mode text not null check(mode in('manual','auto')),status text not null default 'preview' check(status in('preview','pending','running','completed','empty','failed','cancelled')),
 period_start timestamptz not null,period_end timestamptz not null,timezone text not null,settings jsonb not null,
 inputs jsonb not null default '[]',conversation_count int not null default 0,message_count int not null default 0,
 summary text,issues jsonb not null default '[]',error text,model text not null default 'gpt-6-luna',
 input_tokens bigint not null default 0,output_tokens bigint not null default 0,cached_tokens bigint not null default 0,
 charged_micro bigint not null default 0,reserved_micro bigint not null default 0,estimated boolean not null default false,period date,
 lease uuid,leased_until timestamptz,attempted_at timestamptz,provider_response_id text,
 message_id uuid references public.property_messages(id),push_sent_at timestamptz,
 created_at timestamptz not null default now(),finished_at timestamptz,
 check(period_start<period_end),check(charged_micro>=0 and reserved_micro>=0)
);
create unique index briefing_auto_period on omg_private.briefing_runs(property_id,period_start,period_end) where mode='auto';
create index briefing_history on omg_private.briefing_runs(property_id,created_at desc);
create index briefing_pending on omg_private.briefing_runs(created_at) where status in('pending','running');
alter table omg_private.briefing_settings enable row level security;
alter table omg_private.briefing_runs enable row level security;
revoke all on omg_private.briefing_settings,omg_private.briefing_runs from public,anon,authenticated;

create or replace function omg_private.briefing_validate(p_data jsonb) returns jsonb language plpgsql set search_path='' as $$
declare sk text:=coalesce(p_data->>'start_kind','time');ek text:=coalesce(p_data->>'end_kind','time');st time;et time;pr text:=btrim(coalesce(p_data->>'prompt',''));begin
 if sk not in('time','checkout') or ek not in('time','checkin') then raise exception '시작·종료 기준을 선택해주세요.';end if;
 if sk='time' then st:=nullif(p_data->>'start_time','')::time;if st is null then raise exception '시작시간을 선택해주세요.';end if;end if;
 if ek='time' then et:=nullif(p_data->>'end_time','')::time;if et is null then raise exception '종료시간을 선택해주세요.';end if;end if;
 if st=et then raise exception '시작시간과 종료시간을 다르게 선택해주세요.';end if;
 if char_length(pr) not between 1 and 12000 then raise exception '브리핑 프롬프트를 1~12,000자로 입력해주세요.';end if;
 return jsonb_build_object('enabled',coalesce((p_data->>'enabled')::boolean,false),'start_kind',sk,'end_kind',ek,'start_time',st,'end_time',et,'prompt',pr);
end$$;

-- Actual reported attendance; login alone and forced checkout do not form boundaries.
-- Only the last reservation worker's departure and first arrival form shift edges.
create or replace function omg_private.briefing_shift_events(prop uuid) returns table(kind text,at timestamptz) language sql stable set search_path='' as $$
 with sessions as(select w.* from public.work_sessions w join public.employees e on e.id=w.employee_id where w.property_id=prop and e.property_id=prop and e.active and 'reservation'=any(e.duty_roles) and w.checkin_report_at is not null and w.clock_in_at is not null),events as(
 select 'checkin'::text kind,s.clock_in_at at from sessions s where not exists(select 1 from sessions x where x.id<>s.id and x.clock_in_at<s.clock_in_at and coalesce(x.clock_out_at,x.unconfirmed_ended_at,'infinity'::timestamptz)>s.clock_in_at)
 union
 select 'checkout',s.clock_out_at from sessions s where s.checkout_report_at is not null and s.clock_out_at is not null and not exists(select 1 from sessions x where x.id<>s.id and x.clock_in_at<=s.clock_out_at and coalesce(x.clock_out_at,x.unconfirmed_ended_at,'infinity'::timestamptz)>s.clock_out_at))
 select distinct kind,at from events
$$;
create or replace function omg_private.briefing_period(prop uuid,cfg jsonb,p_at timestamptz default now()) returns jsonb language plpgsql stable set search_path='' as $$
declare tz text;st timestamptz;et timestamptz;d date;begin
 select timezone into tz from public.properties where id=prop;tz:=coalesce(tz,'Asia/Seoul');d:=(p_at at time zone tz)::date;
 if cfg->>'end_kind'='time' then et:=(d+(cfg->>'end_time')::time) at time zone tz;if et>p_at then et:=((d-1)+(cfg->>'end_time')::time) at time zone tz;end if;
 else select max(e.at) into et from omg_private.briefing_shift_events(prop)e where kind='checkin' and e.at<=p_at;end if;
 if et is null then raise exception '예약관리 담당자의 출근보고 기록이 없습니다.';end if;
 if cfg->>'start_kind'='time' then d:=(et at time zone tz)::date;st:=(d+(cfg->>'start_time')::time) at time zone tz;if st>=et then st:=((d-1)+(cfg->>'start_time')::time) at time zone tz;end if;
 else select max(e.at) into st from omg_private.briefing_shift_events(prop)e where kind='checkout' and e.at<et;end if;
 if st is null then raise exception '종료시각 이전에 예약관리 담당자의 퇴근보고 기록이 없습니다.';end if;
 if et-st>interval '7 days' then raise exception '최근 출퇴근 기록을 확인해주세요. 브리핑 기간은 최대 7일입니다.';end if;
 return jsonb_build_object('start',st,'end',et,'timezone',tz);
end$$;

-- Select conversations with NEW incoming messages. Include every message in the
-- period and ten earlier messages for context; never include another property's data.
create or replace function omg_private.briefing_inputs(prop uuid,st timestamptz,et timestamptz) returns jsonb language sql stable set search_path='' as $$
 with online_threads as(select distinct booking_id from omg_private.online_messages where property_id=prop and source='guest' and sent_at>=st and sent_at<et),
 online as(select 'online:'||t.booking_id thread_id,coalesce(nullif(b.guest_name,''),'예약 #'||t.booking_id) guest_name,
 coalesce(nullif((select u->>'name' from omg_private.online_connections c cross join lateral jsonb_array_elements(c.properties)p cross join lateral jsonb_array_elements(coalesce(p->'roomTypes','[]'))r cross join lateral jsonb_array_elements(coalesce(r->'units','[]'))u where c.property_id=prop and p->>'id'=c.beds_property_id::text and r->>'id'=b.data->>'roomId' and u->>'id'=b.data->>'unitId' limit 1),''),'객실 미확인') room_number,b.room_name room_type,
 (select coalesce(jsonb_agg(jsonb_build_object('id',m.id::text,'sender',m.source,'body',m.body,'at',m.sent_at,'attachment',m.attachment_name is not null,'in_period',m.sent_at>=st) order by m.sent_at,m.id),'[]') from (
 select id,source,body,sent_at,attachment_name from omg_private.online_messages where property_id=prop and booking_id=t.booking_id and sent_at>=st and sent_at<et and source in('guest','host')
 union all (select id,source,body,sent_at,attachment_name from omg_private.online_messages where property_id=prop and booking_id=t.booking_id and sent_at<st and source in('guest','host') order by sent_at desc,id desc limit 10))m) messages
 from online_threads t left join omg_private.online_bookings b on b.property_id=prop and b.id=t.booking_id),
 onsite_threads as(select distinct r.id,r.guest_name,r.room_number from public.guest_chat_rooms r join public.guest_chat_messages m on m.room_id=r.id where r.property_id=prop and m.sender_kind='guest' and m.created_at>=st and m.created_at<et),
 onsite as(select 'onsite:'||t.id thread_id,t.guest_name,coalesce(nullif(t.room_number,''),'객실 미확인') room_number,null::text room_type,
 (select coalesce(jsonb_agg(jsonb_build_object('id',m.id::text,'sender',m.sender_kind,'body',m.body,'at',m.created_at,'attachment',m.asset_id is not null,'in_period',m.created_at>=st) order by m.created_at,m.id),'[]') from(
 select id,sender_kind,body,created_at,asset_id from public.guest_chat_messages where room_id=t.id and created_at>=st and created_at<et and sender_kind in('guest','staff','owner','ai')
 union all (select id,sender_kind,body,created_at,asset_id from public.guest_chat_messages where room_id=t.id and created_at<st and sender_kind in('guest','staff','owner','ai') order by created_at desc,id desc limit 10))m) messages from onsite_threads t)
 select coalesce(jsonb_agg(to_jsonb(x) order by thread_id),'[]') from(select * from online union all select * from onsite)x
$$;

create or replace function omg_private.briefing_owner(p_token uuid,prop uuid,action text,data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg jsonb;per jsonb;r omg_private.briefing_runs%rowtype;rid uuid;begin
 if not coalesce(omg_private.can_manage_shared_property(p_token,prop,'account_settings'),false) or not coalesce(omg_private.can_manage_shared_property(p_token,prop,'messages'),false) then raise exception '계정관리와 메시지 조회 권한이 필요합니다.';end if;
 insert into omg_private.briefing_settings(property_id)values(prop)on conflict do nothing;
 if action='save' then
  cfg:=omg_private.briefing_validate(data);
  update omg_private.briefing_settings set enabled=(cfg->>'enabled')::boolean,start_kind=cfg->>'start_kind',end_kind=cfg->>'end_kind',start_time=(cfg->>'start_time')::time,end_time=(cfg->>'end_time')::time,prompt=cfg->>'prompt',enabled_since=case when not enabled and (cfg->>'enabled')::boolean then now() else enabled_since end,updated_at=now() where property_id=prop;
 elsif action='preview' then
  cfg:=omg_private.briefing_validate(data);per:=omg_private.briefing_period(prop,cfg);
  insert into omg_private.briefing_runs(property_id,mode,period_start,period_end,timezone,settings)values(prop,'manual',(per->>'start')::timestamptz,(per->>'end')::timestamptz,per->>'timezone',cfg)returning * into r;
  return jsonb_build_object('ok',true,'run',jsonb_build_object('id',r.id,'period_start',r.period_start,'period_end',r.period_end,'timezone',r.timezone));
 elsif action='run' then
  select * into r from omg_private.briefing_runs where id=(data->>'id')::uuid and property_id=prop and mode='manual' for update;
  if not found then raise exception '실행할 기간을 먼저 확인해주세요.';end if;
  if r.status='preview' then
   if r.created_at<now()-interval '10 minutes' then raise exception '기간 확인이 만료되었습니다. 실행 버튼을 다시 눌러주세요.';end if;
   if exists(select 1 from omg_private.briefing_runs where property_id=prop and status in('pending','running')) then raise exception '진행 중인 브리핑이 있습니다. 실행 로그에서 확인해주세요.';end if;
   update omg_private.briefing_runs set status='pending' where id=r.id;
  end if;
  return jsonb_build_object('ok',true,'id',r.id);
 elsif action='logs' then
  return jsonb_build_object('ok',true,'logs',(select coalesce(jsonb_agg(to_jsonb(x) order by created_at desc),'[]') from(select id,mode,status,period_start,period_end,timezone,conversation_count,message_count,summary,issues,error,model,input_tokens,output_tokens,cached_tokens,charged_micro/1000.0 credits,estimated,created_at,finished_at,message_id from omg_private.briefing_runs where property_id=prop and status<>'preview' order by created_at desc limit 50)x));
 elsif action<>'get' then raise exception '잘못된 요청입니다.';end if;
 return jsonb_build_object('ok',true,'settings',(select to_jsonb(s) from omg_private.briefing_settings s where property_id=prop),'usage',omg_private.ai_summary(prop),'provider_ready',exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null),'timezone',(select timezone from public.properties where id=prop));
end$$;
create or replace function public.bot_briefing_settings(p_access_token uuid,p_property_id uuid,p_action text default 'get',p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.briefing_owner(p_access_token,p_property_id,p_action,p_data)$$;
revoke all on function omg_private.briefing_owner(uuid,uuid,text,jsonb),public.bot_briefing_settings(uuid,uuid,text,jsonb) from public;
grant execute on function omg_private.briefing_owner(uuid,uuid,text,jsonb),public.bot_briefing_settings(uuid,uuid,text,jsonb) to anon,authenticated,service_role;
alter table omg_private.briefing_runs add column message_ids uuid[] not null default '{}';

create or replace function omg_private.briefing_worker(action text,data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare s omg_private.briefing_settings%rowtype;r omg_private.briefing_runs%rowtype;cfg jsonb;per jsonb;items jsonb;res bigint;cost bigint;it bigint;ot bigint;ct bigint;bal bigint;cap bigint;used bigint;reserved bigint;mo date;mid uuid;txt text;chunk text;part int;parts int;err text;begin
 if action='schedule' then
  for s in select * from omg_private.briefing_settings where enabled loop
   begin
    cfg:=to_jsonb(s);per:=omg_private.briefing_period(s.property_id,cfg);
    if (per->>'end')::timestamptz>=s.enabled_since then
     insert into omg_private.briefing_runs(property_id,mode,status,period_start,period_end,timezone,settings)
     values(s.property_id,'auto','pending',(per->>'start')::timestamptz,(per->>'end')::timestamptz,per->>'timezone',cfg) on conflict do nothing;
    end if;
   exception when sqlstate 'P0001' then null; -- Waiting for an actual attendance boundary.
   end;
  end loop;
  -- Preview rows never spend credits; keep the table bounded.
  delete from omg_private.briefing_runs where status='preview' and created_at<now()-interval '1 day';
  return jsonb_build_object('ok',true);
 elsif action='claim' then
  select * into r from omg_private.briefing_runs where status='running' and leased_until<now() order by created_at limit 1 for update skip locked;
  if found then return omg_private.briefing_worker('finish',jsonb_build_object('id',r.id,'lease',r.lease,'error','실행 시간 초과 · 실행 로그를 확인해주세요.','estimated',r.attempted_at is not null))||jsonb_build_object('skip',true);end if;
  select * into r from omg_private.briefing_runs where status='pending' order by created_at limit 1 for update skip locked;
  if not found then return jsonb_build_object('empty',true);end if;
  if r.mode='auto' and not exists(select 1 from omg_private.briefing_settings where property_id=r.property_id and enabled) then update omg_private.briefing_runs set status='cancelled',error='브리핑 사용 해제',finished_at=now() where id=r.id;return jsonb_build_object('skip',true);end if;
  items:=omg_private.briefing_inputs(r.property_id,r.period_start,r.period_end);
  update omg_private.briefing_runs set conversation_count=jsonb_array_length(items),message_count=(select count(*) from jsonb_array_elements(items)t cross join lateral jsonb_array_elements(t->'messages')m where (m->>'in_period')::boolean and m->>'sender'='guest') where id=r.id;
  if items='[]'::jsonb then update omg_private.briefing_runs set status='empty',summary='해당 기간에 새로 수신한 게스트 대화가 없습니다.',finished_at=now() where id=r.id;return jsonb_build_object('skip',true);end if;
  err:=null;
  if octet_length(items::text)+octet_length(r.settings->>'prompt')>240000 then err:='분석할 대화가 너무 많습니다. 기간을 줄여 실행해주세요. 메시지를 임의로 생략하지 않았습니다.';end if;
  if not exists(select 1 from omg_private.ai_provider where enabled and vault_id is not null) then err:='AI 연결을 확인해주세요.';end if;
  if err is not null then update omg_private.briefing_runs set status='failed',error=err,finished_at=now() where id=r.id;return jsonb_build_object('skip',true);end if;
  res:=ceil((octet_length(items::text)+octet_length(r.settings->>'prompt')+16000)*0.1+8192*0.5)::bigint;
  mo:=omg_private.ai_month();
  select balance_micro,monthly_limit_micro into bal,cap from omg_private.ai_wallets where property_id=r.property_id and enabled for update;
  insert into omg_private.ai_usage_month(property_id,month)values(r.property_id,mo)on conflict do nothing;
  select used_micro,reserved_micro into used,reserved from omg_private.ai_usage_month where property_id=r.property_id and month=mo;
  -- Reserve by debit, like online arrivals/outbox; ai_jobs uses reservation-only.
  if bal is null or bal-coalesce((select sum(reserved_micro) from omg_private.ai_jobs where property_id=r.property_id and status='leased'),0)<res or cap-used-reserved<res then
   update omg_private.briefing_runs set status='failed',error='AI 크레딧 잔액 또는 월 사용 한도가 부족합니다.',finished_at=now() where id=r.id;return jsonb_build_object('skip',true);
  end if;
  update omg_private.ai_wallets set balance_micro=balance_micro-res,updated_at=now() where property_id=r.property_id;
  update omg_private.ai_usage_month set reserved_micro=reserved_micro+res where property_id=r.property_id and month=mo;
  update omg_private.briefing_runs set status='running',inputs=items,period=mo,reserved_micro=res,lease=gen_random_uuid(),leased_until=now()+interval '3 minutes' where id=r.id returning * into r;
  return jsonb_build_object('id',r.id,'lease',r.lease,'property_id',r.property_id,'inputs',r.inputs,'prompt',r.settings->>'prompt','period_start',r.period_start,'period_end',r.period_end,'timezone',r.timezone);
 elsif action in('attempt','finish') then
  select * into r from omg_private.briefing_runs where id=(data->>'id')::uuid for update;
  if not found or r.status<>'running' or r.lease is distinct from (data->>'lease')::uuid then return jsonb_build_object('ok',true,'stale',true);end if;
  if action='attempt' then
   if r.attempted_at is not null then return jsonb_build_object('ok',true,'stale',true);end if;
   update omg_private.briefing_runs set attempted_at=now() where id=r.id;return jsonb_build_object('ok',true);
  end if;
  it:=greatest(0,coalesce((data->>'input_tokens')::bigint,0));ot:=greatest(0,coalesce((data->>'output_tokens')::bigint,0));ct:=least(it,greatest(0,coalesce((data->>'cached_tokens')::bigint,0)));
  cost:=least(r.reserved_micro,case when coalesce((data->>'estimated')::boolean,false) then r.reserved_micro else ceil((it-ct)*0.10+ct*0.01+ot*0.50)::bigint end);
  perform 1 from omg_private.ai_wallets where property_id=r.property_id for update;
  update omg_private.ai_wallets set balance_micro=balance_micro+r.reserved_micro-cost,updated_at=now() where property_id=r.property_id;
  update omg_private.ai_usage_month set reserved_micro=reserved_micro-r.reserved_micro,used_micro=used_micro+cost,responses=responses+case when cost>0 then 1 else 0 end,input_tokens=input_tokens+it,output_tokens=output_tokens+ot where property_id=r.property_id and month=r.period;
  err:=nullif(data->>'error','');txt:=data->>'summary';
  if err is null and nullif(txt,'') is null then err:='브리핑 결과가 비어 있습니다.';end if;
  update omg_private.briefing_runs set status=case when err is null then 'completed' else 'failed' end,error=left(err,300),summary=txt,issues=coalesce(data->'issues','[]'),input_tokens=it,output_tokens=ot,cached_tokens=ct,charged_micro=cost,reserved_micro=0,estimated=coalesce((data->>'estimated')::boolean,false),provider_response_id=data->>'response_id',inputs='[]',finished_at=now() where id=r.id;
  -- Manual test runs display a result in the settings only. Scheduled summaries
  -- go to the property's owners, shared-message owners and reservation staff.
  if err is null and r.mode='auto' and jsonb_array_length(coalesce(data->'issues','[]'))>0 and exists(select 1 from omg_private.briefing_settings where property_id=r.property_id and enabled) then
   parts:=ceil(char_length(txt)/1700.0)::int;
   for part in 1..parts loop
    chunk:='[메시지 브리핑] '||to_char(r.period_start at time zone r.timezone,'MM.DD HH24:MI')||' ~ '||to_char(r.period_end at time zone r.timezone,'MM.DD HH24:MI')||case when parts>1 then ' ('||part||'/'||parts||')' else '' end||E'\n'||substring(txt from (part-1)*1700+1 for 1700);
    insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type,source,external_message_id)
    select business_id,id,'system',chunk,'normal','general','bot_briefing',r.id::text||':'||part from public.properties where id=r.property_id returning id into mid;
    insert into public.property_message_recipients(message_id,recipient_type,owner_id,recipient_key)
    select mid,'owner',o.id,'owner:'||o.id from public.owners o where o.active and (o.property_id=r.property_id or exists(select 1 from public.property_share_requests sh where sh.requester_property_id=o.property_id and sh.target_property_id=r.property_id and sh.status='approved' and 'messages'=any(sh.requested_permissions)));
    insert into public.property_message_recipients(message_id,recipient_type,employee_id,recipient_key)
    select mid,'staff',e.id,'employee:'||e.id from public.employees e where e.active and e.property_id=r.property_id and 'reservation'=any(e.duty_roles);
    update omg_private.briefing_runs set message_id=coalesce(message_id,mid),message_ids=array_append(message_ids,mid) where id=r.id;
   end loop;
  end if;
  return jsonb_build_object('ok',true,'id',r.id);
 elsif action='pushes' then
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'message_ids',message_ids)) from(select id,message_ids from omg_private.briefing_runs where push_sent_at is null and cardinality(message_ids)>0 and finished_at>now()-interval '1 day' order by finished_at limit 8)x),'[]');
 elsif action='pushed' then
  update omg_private.briefing_runs set push_sent_at=now() where id=(data->>'id')::uuid;return jsonb_build_object('ok',true);
 end if;
 raise exception '잘못된 작업입니다.';
end$$;
create or replace function public.bot_briefing_worker(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select omg_private.briefing_worker(p_action,p_data)$$;
revoke all on function omg_private.briefing_worker(text,jsonb),public.bot_briefing_worker(text,jsonb) from public,anon,authenticated;
grant execute on function omg_private.briefing_worker(text,jsonb),public.bot_briefing_worker(text,jsonb) to service_role;
revoke all on function omg_private.briefing_default_prompt(),omg_private.briefing_validate(jsonb),omg_private.briefing_shift_events(uuid),omg_private.briefing_period(uuid,jsonb,timestamptz),omg_private.briefing_inputs(uuid,timestamptz,timestamptz) from public,anon,authenticated;

create or replace function public.get_briefing_push_dispatch(p_message_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.property_messages%rowtype;mode text;name text;begin
 select * into m from public.property_messages where id=p_message_id and source='bot_briefing';if not found then return jsonb_build_object('ok',false);end if;
 select coalesce(b.alert_mode,'normal'),coalesce(b.display_name,'OMS 알림') into mode,name from public.properties p left join public.notification_bots b on b.property_id=p.id where p.id=m.property_id;
 return jsonb_build_object('ok',true,'message_id',m.id,'message',m.message,'sender_label',name||' · 브리핑','priority',case when mode='urgent' then 'urgent' else 'normal' end)||omg_private.bot_recipient_modes(m.id,mode);
end$$;
revoke all on function public.get_briefing_push_dispatch(uuid) from public,anon,authenticated;
grant execute on function public.get_briefing_push_dispatch(uuid) to service_role;

-- The worker runs independently of open browser windows using the existing
-- Vault worker secret. The Edge worker rechecks it before processing.
select cron.schedule('oms-bot-briefing','* * * * *',$job$
 select net.http_post(url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/bot-briefing/worker',headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select decrypted_secret from vault.decrypted_secrets where name='oms_guest_ai_worker_secret')),body:='{}'::jsonb,timeout_milliseconds:=1000)
$job$);
