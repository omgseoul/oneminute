-- Owner announcements, employee schedules and configurable attendance warnings.
begin;

alter table public.employees
  add column if not exists scheduled_clock_in time,
  add column if not exists scheduled_clock_out time;

alter table public.property_message_recipients
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledged_name text;

alter table public.property_messages drop constraint if exists property_messages_message_type_check;
alter table public.property_messages add constraint property_messages_message_type_check
  check(message_type in('general','emergency_report','attendance_approval','property_share_approval','announcement'));

create table if not exists public.attendance_warning_rules(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  property_id uuid not null references public.properties(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete cascade,
  event_type text not null check(event_type in('clock_in','clock_out')),
  comparison text not null check(comparison in('late','early')),
  threshold_minutes integer not null check(threshold_minutes between 0 and 720),
  message text not null check(char_length(btrim(message)) between 1 and 1000),
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create index if not exists attendance_warning_rules_property_idx
  on public.attendance_warning_rules(property_id,active,event_type);

create table if not exists public.attendance_warning_deliveries(
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.attendance_warning_rules(id) on delete cascade,
  work_session_id uuid not null references public.work_sessions(id) on delete cascade,
  event_type text not null check(event_type in('clock_in','clock_out')),
  message_id uuid not null references public.property_messages(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  unique(rule_id,work_session_id,event_type)
);

alter table public.attendance_warning_rules enable row level security;
alter table public.attendance_warning_deliveries enable row level security;
revoke all on table public.attendance_warning_rules,public.attendance_warning_deliveries from public,anon,authenticated;

create or replace function public.get_work_app_config(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_owner_session public.owner_sessions%rowtype;v_can_manage boolean:=false;
  v_employees jsonb:='[]'::jsonb;v_administrators jsonb:='[]'::jsonb;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then
    select * into v_property from public.properties where id=v_owner_session.property_id;v_can_manage:=true;
  else
    select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    select * into v_employee from public.employees where id=v_session.employee_id;
    select * into v_property from public.properties where id=v_session.property_id;
  end if;
  if v_can_manage then
    select coalesce(jsonb_agg(jsonb_build_object('employee_id',e.id,'display_name',e.display_name,'role',e.role,
      'pin_ready',e.pin_hash is not null,'report_config',e.report_config,
      'scheduled_clock_in',case when e.scheduled_clock_in is null then null else to_char(e.scheduled_clock_in,'HH24:MI') end,
      'scheduled_clock_out',case when e.scheduled_clock_out is null then null else to_char(e.scheduled_clock_out,'HH24:MI') end)
      order by e.created_at,e.id),'[]'::jsonb)
    into v_employees from public.employees e where e.property_id=v_property.id and e.active and e.role<>'owner';
    select coalesce(jsonb_agg(jsonb_build_object('owner_id',o.id,'display_name',o.display_name,'login_id',o.login_id,
      'is_current',o.id=v_owner_session.owner_id) order by o.created_at,o.id),'[]'::jsonb)
    into v_administrators from public.owners o where o.property_id=v_property.id and o.active;
  end if;
  return jsonb_build_object('ok',true,'property',jsonb_build_object('property_id',v_property.id,'name',v_property.name,
    'rooms',v_property.rooms,'room_types',v_property.room_types,'business_type',v_property.business_type,
    'custom_report_fields',v_property.custom_report_fields,'management_number',v_property.management_number,'notice',v_property.notice),
    'report_config',case when v_can_manage then null else v_employee.report_config end,
    'employees',v_employees,'administrators',v_administrators,'can_manage',v_can_manage);
end;
$$;

create or replace function public.mark_property_message_read(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_type text;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s
  join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s
    join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select m.message_type into v_type from public.property_messages m where m.id=p_message_id and m.property_id=v_property_id;
  if v_type='announcement' and v_employee_id is not null then
    return jsonb_build_object('ok',false,'code','acknowledgement_required','message','이름 입력과 이해했음 확인이 필요합니다.');
  end if;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m where r.message_id=m.id and m.id=p_message_id and m.property_id=v_property_id
    and((v_owner_id is not null and r.owner_id=v_owner_id)or(v_employee_id is not null and r.employee_id=v_employee_id));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','메세지를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.acknowledge_announcement(
  p_access_token uuid,p_message_id uuid,p_employee_name text,p_understood boolean
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_name text;v_recipient_id uuid;
begin
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 확인해주세요.'); end if;
  select display_name into v_name from public.employees where id=v_session.employee_id;
  if not coalesce(p_understood,false) then return jsonb_build_object('ok',false,'code','understanding_required','message','이해했음을 체크해주세요.'); end if;
  if btrim(coalesce(p_employee_name,''))<>v_name then return jsonb_build_object('ok',false,'code','name_mismatch','message','본인 이름을 정확히 입력해주세요.'); end if;
  select r.id into v_recipient_id from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.message_id=p_message_id and r.employee_id=v_session.employee_id and m.message_type='announcement';
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','확인할 공지를 찾을 수 없습니다.'); end if;
  update public.property_message_recipients set acknowledged_at=coalesce(acknowledged_at,clock_timestamp()),
    acknowledged_name=v_name,read_at=coalesce(read_at,clock_timestamp()) where id=v_recipient_id;
  return jsonb_build_object('ok',true,'acknowledged_at',clock_timestamp(),'employee_name',v_name);
end;
$$;

create or replace function public.get_message_push_dispatch(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_employee_id uuid;v_property_id uuid;v_message public.property_messages%rowtype;v_number integer;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  end if;
  select * into v_message from public.property_messages m where m.id=p_message_id and m.property_id=v_property_id and(
    (v_owner_id is not null and m.sender_owner_id=v_owner_id)or(v_employee_id is not null and m.sender_employee_id=v_employee_id)
    or(v_employee_id is not null and m.sender_type='system' and exists(select 1 from public.property_message_recipients r
      where r.message_id=m.id and r.employee_id=v_employee_id)));
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','전송할 메세지를 찾을 수 없습니다.'); end if;
  select management_number into v_number from public.properties where id=v_property_id;
  return jsonb_build_object('ok',true,'management_number',v_number,'message_id',v_message.id,
    'message',case when v_message.priority='urgent' then v_message.message else '[[OMG_NORMAL_MESSAGE]]'||v_message.message end,
    'priority',v_message.priority,'message_type',v_message.message_type,
    'sender_label',case when v_message.sender_type='owner' then '사장님' when v_message.sender_type='system' then '근태관리'
      else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb));
end;
$$;

create or replace function public.evaluate_attendance_warnings(p_access_token uuid,p_report_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_session public.work_sessions%rowtype;v_employee public.employees%rowtype;v_property public.properties%rowtype;
  v_actual timestamptz;v_expected timestamptz;v_scheduled time;v_diff integer;v_rule public.attendance_warning_rules%rowtype;
  v_message_id uuid;v_message_ids jsonb:='[]'::jsonb;v_text text;v_triggered boolean;
begin
  if p_report_type not in('clock_in','clock_out') then return jsonb_build_object('ok',false,'message','보고 종류를 확인해주세요.'); end if;
  select s.* into v_session from public.work_sessions s join public.employees e on e.id=s.employee_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
    and e.active and s.status in('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.'); end if;
  select * into v_employee from public.employees where id=v_session.employee_id;
  select * into v_property from public.properties where id=v_session.property_id;
  if p_report_type='clock_in' then v_actual:=v_session.clock_in_at;v_scheduled:=v_employee.scheduled_clock_in;
  else v_actual:=v_session.clock_out_at;v_scheduled:=v_employee.scheduled_clock_out;end if;
  if v_actual is null or v_scheduled is null then return jsonb_build_object('ok',true,'message_ids',v_message_ids); end if;
  v_expected:=(v_session.work_date+v_scheduled+case when p_report_type='clock_out' and v_employee.scheduled_clock_in is not null
    and v_scheduled<=v_employee.scheduled_clock_in then interval '1 day' else interval '0' end) at time zone v_property.timezone;
  v_diff:=floor(extract(epoch from(v_actual-v_expected))/60)::integer;
  for v_rule in select * from public.attendance_warning_rules where property_id=v_session.property_id
    and employee_id=v_session.employee_id and event_type=p_report_type and active order by created_at loop
    v_triggered:=(v_rule.comparison='late' and v_diff>=v_rule.threshold_minutes)
      or(v_rule.comparison='early' and v_diff<=-v_rule.threshold_minutes);
    if v_triggered and not exists(select 1 from public.attendance_warning_deliveries d
      where d.rule_id=v_rule.id and d.work_session_id=v_session.id and d.event_type=p_report_type) then
      v_text:=replace(replace(replace(replace(v_rule.message,'{이름}',v_employee.display_name),'{예정시간}',to_char(v_expected at time zone v_property.timezone,'HH24:MI')),
        '{실제시간}',to_char(v_actual at time zone v_property.timezone,'HH24:MI')),'{차이분}',abs(v_diff)::text);
      insert into public.property_messages(business_id,property_id,sender_type,message,priority,message_type)
      values(v_property.business_id,v_property.id,'system',v_text,'normal','announcement') returning id into v_message_id;
      insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
      values(v_message_id,'employee:'||v_employee.id,'staff',v_employee.id);
      insert into public.attendance_warning_deliveries(rule_id,work_session_id,event_type,message_id)
      values(v_rule.id,v_session.id,p_report_type,v_message_id);
      v_message_ids:=v_message_ids||jsonb_build_array(v_message_id);
    end if;
  end loop;
  return jsonb_build_object('ok',true,'message_ids',v_message_ids,'difference_minutes',v_diff);
end;
$$;

revoke all on function public.mark_property_message_read(uuid,uuid) from public;
revoke all on function public.acknowledge_announcement(uuid,uuid,text,boolean) from public;
revoke all on function public.get_message_push_dispatch(uuid,uuid) from public;
revoke all on function public.evaluate_attendance_warnings(uuid,text) from public;
grant execute on function public.mark_property_message_read(uuid,uuid) to anon,authenticated;
grant execute on function public.acknowledge_announcement(uuid,uuid,text,boolean) to anon,authenticated;
grant execute on function public.get_message_push_dispatch(uuid,uuid) to anon,authenticated;
grant execute on function public.evaluate_attendance_warnings(uuid,text) to anon,authenticated;

create or replace function public.save_employee_accounts(p_access_token uuid,p_employees jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_business_id uuid;v_property_id uuid;v_item jsonb;v_employee_id uuid;v_name text;v_pin text;
  v_pin_hash text;v_crypto_schema text;v_clock_in time;v_clock_out time;
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근무자를 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_employees)<>'array' or jsonb_array_length(p_employees)<1 or jsonb_array_length(p_employees)>50 then
    return jsonb_build_object('ok',false,'code','invalid_employees','message','근무자 계정을 확인해주세요.');
  end if;
  select n.nspname into strict v_crypto_schema from pg_catalog.pg_extension x
  join pg_catalog.pg_namespace n on n.oid=x.extnamespace where x.extname='pgcrypto';
  for v_item in select value from jsonb_array_elements(p_employees) loop
    v_name:=btrim(coalesce(v_item->>'display_name',''));v_pin:=btrim(coalesce(v_item->>'pin',''));
    if char_length(v_name) not between 1 and 50 or(v_pin<>'' and v_pin!~'^[0-9]{6,8}$') then
      return jsonb_build_object('ok',false,'code','invalid_employee','message','근무자 이름과 PIN(숫자 6~8자리)을 확인해주세요.');
    end if;
    begin
      v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
      v_clock_in:=nullif(v_item->>'scheduled_clock_in','')::time;
      v_clock_out:=nullif(v_item->>'scheduled_clock_out','')::time;
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_employee','message',v_name||'의 출퇴근 시간을 확인해주세요.');
    end;
    if v_pin<>'' then
      execute format('select %I.crypt($1,%I.gen_salt(''bf'',10))',v_crypto_schema,v_crypto_schema) into v_pin_hash using v_pin;
    else v_pin_hash:=null;end if;
    if v_employee_id is null then
      if v_pin_hash is null then return jsonb_build_object('ok',false,'code','pin_required','message',v_name||'의 PIN을 입력해주세요.'); end if;
      insert into public.employees(business_id,property_id,display_name,pin_hash,role,active,scheduled_clock_in,scheduled_clock_out)
      values(v_business_id,v_property_id,v_name,v_pin_hash,'staff',true,v_clock_in,v_clock_out);
    else
      update public.employees set display_name=v_name,pin_hash=coalesce(v_pin_hash,pin_hash),
        scheduled_clock_in=v_clock_in,scheduled_clock_out=v_clock_out,login_failures=0,login_locked_until=null
      where id=v_employee_id and property_id=v_property_id and business_id=v_business_id and active and role<>'owner';
      if not found then return jsonb_build_object('ok',false,'code','unknown_employee','message','존재하지 않는 근무자가 포함되어 있습니다.'); end if;
    end if;
  end loop;
  return public.get_work_app_config(p_access_token);
end;
$$;

create or replace function public.list_attendance_warning_rules(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_property_id uuid;v_rules jsonb:='[]'::jsonb;
begin
  select s.property_id into v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('rule_id',r.id,'employee_id',r.employee_id,'event_type',r.event_type,
    'comparison',r.comparison,'threshold_minutes',r.threshold_minutes,'message',r.message,'active',r.active)
    order by r.created_at,r.id),'[]'::jsonb) into v_rules
  from public.attendance_warning_rules r where r.property_id=v_property_id;
  return jsonb_build_object('ok',true,'rules',v_rules);
end;
$$;

create or replace function public.save_attendance_warning_rules(p_access_token uuid,p_rules jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_business_id uuid;v_property_id uuid;v_item jsonb;v_rule_id uuid;v_employee_id uuid;
  v_event text;v_comparison text;v_minutes integer;v_message text;v_active boolean;v_keep uuid[]:='{}'::uuid[];
begin
  select s.business_id,s.property_id into v_business_id,v_property_id from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자 계정만 근태 워닝을 관리할 수 있습니다.'); end if;
  if jsonb_typeof(p_rules)<>'array' or jsonb_array_length(p_rules)>50 then
    return jsonb_build_object('ok',false,'code','invalid_rules','message','근무시간 워닝 조건을 확인해주세요.');
  end if;
  for v_item in select value from jsonb_array_elements(p_rules) loop
    begin
      v_rule_id:=nullif(v_item->>'rule_id','')::uuid;v_employee_id:=nullif(v_item->>'employee_id','')::uuid;
      v_minutes:=coalesce((v_item->>'threshold_minutes')::integer,0);
    exception when invalid_text_representation then
      return jsonb_build_object('ok',false,'code','invalid_rule','message','근무시간 워닝 조건을 확인해주세요.');
    end;
    v_event:=coalesce(v_item->>'event_type','');v_comparison:=coalesce(v_item->>'comparison','');
    v_message:=btrim(coalesce(v_item->>'message',''));v_active:=coalesce((v_item->>'active')::boolean,true);
    if v_employee_id is null or not exists(select 1 from public.employees e where e.id=v_employee_id and e.property_id=v_property_id and e.active and e.role<>'owner')
      or v_event not in('clock_in','clock_out') or v_comparison not in('late','early') or v_minutes not between 0 and 720
      or char_length(v_message) not between 1 and 1000 then
      return jsonb_build_object('ok',false,'code','invalid_rule','message','대상·조건·시간·공지 내용을 모두 확인해주세요.');
    end if;
    if(v_event='clock_in' and(select scheduled_clock_in from public.employees where id=v_employee_id)is null)
      or(v_event='clock_out' and(select scheduled_clock_out from public.employees where id=v_employee_id)is null) then
      return jsonb_build_object('ok',false,'code','schedule_required','message','선택한 근무자의 예정 출퇴근 시간을 먼저 입력해주세요.');
    end if;
    if v_rule_id is null then
      insert into public.attendance_warning_rules(business_id,property_id,employee_id,event_type,comparison,threshold_minutes,message,active)
      values(v_business_id,v_property_id,v_employee_id,v_event,v_comparison,v_minutes,v_message,v_active) returning id into v_rule_id;
    else
      update public.attendance_warning_rules set employee_id=v_employee_id,event_type=v_event,comparison=v_comparison,
        threshold_minutes=v_minutes,message=v_message,active=v_active,updated_at=clock_timestamp()
      where id=v_rule_id and property_id=v_property_id;
      if not found then return jsonb_build_object('ok',false,'code','not_found','message','수정할 워닝 조건을 찾지 못했습니다.'); end if;
    end if;
    v_keep:=array_append(v_keep,v_rule_id);
  end loop;
  delete from public.attendance_warning_rules where property_id=v_property_id and not(id=any(v_keep));
  return public.list_attendance_warning_rules(p_access_token);
end;
$$;

create or replace function public.send_shared_property_message(
  p_access_token uuid,p_recipient_employee_ids uuid[],p_recipient_owner_ids uuid[],p_message text,
  p_priority text default 'normal',p_message_type text default 'general')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property public.properties%rowtype;
  v_sender_type text;v_message_id uuid;v_text text:=btrim(coalesce(p_message,''));
  v_employee_ids uuid[]:=coalesce(p_recipient_employee_ids,'{}'::uuid[]);v_owner_ids uuid[]:=coalesce(p_recipient_owner_ids,'{}'::uuid[]);
  v_employee_count integer:=0;v_owner_count integer:=0;
begin
  if char_length(v_text) not between 1 and 2000 then return jsonb_build_object('ok',false,'code','invalid_message','message','메세지 내용을 입력해주세요.'); end if;
  if p_priority not in('normal','urgent') or p_message_type not in('general','emergency_report','announcement') then
    return jsonb_build_object('ok',false,'code','invalid_message_type','message','메세지 종류를 확인해주세요.'); end if;
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_sender_type:='owner';select * into v_property from public.properties where id=v_owner_session.property_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    if p_message_type='announcement' then return jsonb_build_object('ok',false,'code','owner_required','message','공지는 관리자만 보낼 수 있습니다.'); end if;
    v_sender_type:='staff';select * into v_property from public.properties where id=v_work_session.property_id;
    v_employee_ids:=array_remove(v_employee_ids,v_work_session.employee_id);
  end if;
  if p_message_type='announcement' then
    p_priority:='normal';v_owner_ids:='{}'::uuid[];
    select coalesce(array_agg(e.id order by e.created_at,e.id),'{}'::uuid[]) into v_employee_ids
    from public.employees e where e.property_id=v_property.id and e.active and e.role<>'owner';
  end if;
  select count(*)::integer into v_employee_count from public.employees e
  where e.active and e.role<>'owner' and e.id=any(v_employee_ids) and(
    e.property_id=v_property.id or exists(select 1 from public.property_share_requests r
      where r.status='approved' and 'messages'=any(r.requested_permissions) and(
        (r.requester_property_id=v_property.id and r.target_property_id=e.property_id)
        or(v_sender_type='staff' and r.target_property_id=v_property.id and r.requester_property_id=e.property_id))));
  if v_employee_count<>coalesce(cardinality(v_employee_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 직원이 포함되어 있습니다.'); end if;
  select count(*)::integer into v_owner_count from public.owners o where o.active and o.id=any(v_owner_ids) and(
    (v_sender_type='staff' and(o.property_id=v_property.id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property.id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions))))
    or(v_sender_type='owner' and o.property_id=v_property.id and o.id<>v_owner_session.owner_id));
  if v_owner_count<>coalesce(cardinality(v_owner_ids),0) then return jsonb_build_object('ok',false,'code','invalid_recipient','message','메세지 공유 권한이 없는 관리자가 포함되어 있습니다.'); end if;
  if v_employee_count+v_owner_count=0 then return jsonb_build_object('ok',false,'code','recipient_required','message','받는 사람을 한 명 이상 선택해주세요.'); end if;
  insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,message_type)
  values(v_property.business_id,v_property.id,v_sender_type,case when v_sender_type='owner' then v_owner_session.owner_id end,
    case when v_sender_type='staff' then v_work_session.employee_id end,v_text,p_priority,p_message_type) returning id into v_message_id;
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id)
  select v_message_id,'employee:'||e.id,'staff',e.id from public.employees e where e.id=any(v_employee_ids);
  insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id)
  select v_message_id,'owner:'||o.id,'owner',o.id from public.owners o where o.id=any(v_owner_ids);
  return jsonb_build_object('ok',true,'message_id',v_message_id,'priority',p_priority,'message_type',p_message_type,
    'recipient_count',v_employee_count+v_owner_count,'sent_at',clock_timestamp());
end;
$$;

create or replace function public.list_property_messages(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_session public.owner_sessions%rowtype;v_work_session public.work_sessions%rowtype;v_property_id uuid;
  v_owner_id uuid;v_employee_id uuid;v_is_owner boolean:=false;v_items jsonb:='[]'::jsonb;v_recipients jsonb:='[]'::jsonb;v_unread integer:=0;
begin
  select s.* into v_owner_session from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;v_property_id:=v_owner_session.property_id;v_owner_id:=v_owner_session.owner_id;
  else
    select s.* into v_work_session from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
    v_property_id:=v_work_session.property_id;v_employee_id:=v_work_session.employee_id;
  end if;
  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients from(
    select jsonb_build_object('recipient_key','owner:'||o.id,'recipient_type','owner','owner_id',o.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
      'sort_key','1'||p.name||e.created_at::text)x from public.employees e join public.properties p on p.id=e.property_id
    where e.active and e.role<>'owner' and e.id<>coalesce(v_employee_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and(e.property_id=v_property_id or exists(select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id))))
  )q;
  select count(*)::integer into v_unread from public.property_message_recipients r
  where r.read_at is null and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id));
  with visible as(
    select m.*,r.read_at current_read_at,r.acknowledged_at current_acknowledged_at,r.acknowledged_name current_acknowledged_name,
      case when v_is_owner then m.sender_type='owner' and m.sender_owner_id=v_owner_id
      else m.sender_type='staff' and m.sender_employee_id=v_employee_id end is_sender
    from public.property_messages m left join public.property_message_recipients r on r.message_id=m.id
      and((v_is_owner and r.owner_id=v_owner_id)or(not v_is_owner and r.employee_id=v_employee_id))
    where((v_is_owner and m.sender_type='owner' and m.sender_owner_id=v_owner_id)
      or(not v_is_owner and m.sender_type='staff' and m.sender_employee_id=v_employee_id)or r.id is not null)
      and(m.message_type<>'property_share_approval' or m.id=(select pm.id from public.property_messages pm
        where pm.property_share_request_id=m.property_share_request_id order by pm.created_at desc,pm.id desc limit 1))
    order by m.created_at desc limit 150)
  select coalesce(jsonb_agg(jsonb_build_object('message_id',m.id,'message',m.message,'priority',m.priority,'message_type',m.message_type,
    'created_at',m.created_at,'read_at',m.current_read_at,'acknowledged_at',m.current_acknowledged_at,
    'acknowledged_name',m.current_acknowledged_name,'is_sender',m.is_sender,'sender_type',m.sender_type,
    'sender_owner_id',m.sender_owner_id,'sender_employee_id',m.sender_employee_id,
    'sender_label',case when m.message_type='property_share_approval' then coalesce(sp.name,'다른 지점')||' 관리자'
      when m.sender_type='owner' then case when sop.id=v_property_id then '사장님' else sop.name||' 사장님' end
      when m.sender_type='staff' then case when sep.id=v_property_id then coalesce(se.display_name,'직원') else coalesce(se.display_name,'직원')||' · '||coalesce(sep.name,'다른 지점') end
      when m.sender_type='system' then '근태관리' else '시스템' end,
    'recipient_labels',coalesce((select jsonb_agg(case when rr.recipient_type='owner' then case when rop.id=m.property_id then '사장님' else rop.name||' 사장님' end
      else case when rep.id=m.property_id then re.display_name else re.display_name||' · '||rep.name end end order by rr.recipient_key)
      from public.property_message_recipients rr left join public.employees re on re.id=rr.employee_id
      left join public.properties rep on rep.id=re.property_id left join public.owners ro on ro.id=rr.owner_id
      left join public.properties rop on rop.id=ro.property_id where rr.message_id=m.id),'[]'::jsonb),
    'announcement_acknowledgements',coalesce((select jsonb_agg(jsonb_build_object('employee_name',re.display_name,
      'acknowledged_at',rr.acknowledged_at) order by re.display_name) from public.property_message_recipients rr
      join public.employees re on re.id=rr.employee_id where rr.message_id=m.id),'[]'::jsonb),
    'attendance_request_id',m.attendance_request_id,'property_share_request_id',m.property_share_request_id,
    'approval_status',coalesce(ar.status,psr.status),'share_permissions',psr.requested_permissions,
    'share_source_name',sp.name,'share_target_name',tp.name,'original_clock_in_at',ar.original_clock_in_at,
    'original_clock_out_at',ar.original_clock_out_at,'requested_clock_in_at',ar.requested_clock_in_at,
    'requested_clock_out_at',ar.requested_clock_out_at,'work_date',ws.work_date) order by m.created_at desc),'[]'::jsonb) into v_items
  from visible m left join public.employees se on se.id=m.sender_employee_id left join public.properties sep on sep.id=se.property_id
  left join public.owners so on so.id=m.sender_owner_id left join public.properties sop on sop.id=so.property_id
  left join public.attendance_adjustment_requests ar on ar.id=m.attendance_request_id left join public.work_sessions ws on ws.id=ar.work_session_id
  left join public.property_share_requests psr on psr.id=m.property_share_request_id
  left join public.properties sp on sp.id=psr.requester_property_id left join public.properties tp on tp.id=psr.target_property_id;
  return jsonb_build_object('ok',true,'can_manage',v_is_owner,'current_employee_name',case when v_is_owner then null else(select display_name from public.employees where id=v_employee_id)end,
    'unread_count',v_unread,'recipients',v_recipients,'messages',v_items);
end;
$$;

revoke all on function public.list_attendance_warning_rules(uuid) from public;
revoke all on function public.save_attendance_warning_rules(uuid,jsonb) from public;
grant execute on function public.list_attendance_warning_rules(uuid) to anon,authenticated;
grant execute on function public.save_attendance_warning_rules(uuid,jsonb) to anon,authenticated;

commit;

select 'announcement and attendance warning features installed' as migration_status;
