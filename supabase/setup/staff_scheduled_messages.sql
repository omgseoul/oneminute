begin;
create table omg_private.staff_scheduled_messages(
 id uuid primary key default gen_random_uuid(),actor_key text not null,client_id uuid not null,property_id uuid not null references public.properties(id),
 peer text not null,body text not null check(length(body) between 1 and 2000),priority text not null check(priority in('normal','urgent')),
 mode text not null check(mode in('time','checkin')),send_at timestamptz,trigger_employee_id uuid references public.employees(id),
 baseline_session uuid,ready_at timestamptz,armed_at timestamptz not null default clock_timestamp(),
 status text not null default 'pending' check(status in('pending','sent','failed','cancelled')),revision integer not null default 1,
 attachment_hash text,attachment_bytes bytea,attachment_mime text,preview_bytes bytea,error text,message_id uuid references public.property_messages(id),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 unique(actor_key,client_id),check((mode='time' and send_at is not null and trigger_employee_id is null) or (mode='checkin' and send_at is null and trigger_employee_id is not null))
);
alter table omg_private.staff_scheduled_messages enable row level security;
revoke all on omg_private.staff_scheduled_messages from public,anon,authenticated;
create index staff_schedule_due on omg_private.staff_scheduled_messages(send_at) where status='pending' and mode='time';
create index staff_schedule_checkin on omg_private.staff_scheduled_messages(trigger_employee_id) where status='pending' and mode='checkin';
create index staff_schedule_actor on omg_private.staff_scheduled_messages(actor_key,peer,created_at desc);

create function omg_private.staff_schedule_actor(p_actor text) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('key',p_actor,'kind','owner','id',o.id,'property_id',o.property_id) from public.owners o where 'owner:'||o.id=p_actor and o.active
 union all select jsonb_build_object('key',p_actor,'kind','staff','id',e.id,'property_id',e.property_id) from public.employees e where 'employee:'||e.id=p_actor and e.active and e.role<>'owner'
$$;

CREATE OR REPLACE FUNCTION omg_private.staff_schedule_recipients(p_actor jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare a jsonb;v_property_id uuid;v_employee_id uuid;v_is_owner boolean;v_recipients jsonb;
begin
 a:=p_actor;
 if a->>'key' is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 v_property_id:=(a->>'property_id')::uuid;v_is_owner:=a->>'kind'='owner';
 if not v_is_owner then v_employee_id:=(a->>'id')::uuid;end if;
  select coalesce(jsonb_agg(x order by x->>'sort_key'),'[]'::jsonb) into v_recipients from(
    select jsonb_build_object('recipient_key','owner:'||o.id,'recipient_type','owner','owner_id',o.id,
      'property_id',p.id,'property_name',p.name,'base_name',o.display_name,'profile_image',o.profile_image,'display_name',case when p.id=v_property_id then '사장님' else p.name||' 사장님' end,
      'sort_key','0'||p.name||o.created_at::text)x from public.owners o join public.properties p on p.id=o.property_id
    where not v_is_owner and o.active and(o.property_id=v_property_id or exists(select 1 from public.property_share_requests r
      where r.target_property_id=v_property_id and r.requester_property_id=o.property_id and r.status='approved' and 'messages'=any(r.requested_permissions)))
    union all
    select jsonb_build_object('recipient_key','employee:'||e.id,'recipient_type','staff','employee_id',e.id,
      'property_id',p.id,'property_name',p.name,'base_name',e.display_name,'profile_image',e.profile_image,'work_state',omg_private.target_work_state(e.id),'display_name',case when p.id=v_property_id then e.display_name else e.display_name||' · '||p.name end,
      'sort_key','1'||p.name||e.created_at::text)x from public.employees e join public.properties p on p.id=e.property_id
    where e.active and e.role<>'owner' and e.id<>coalesce(v_employee_id,'00000000-0000-0000-0000-000000000000'::uuid)
      and(e.property_id=v_property_id or exists(select 1 from public.property_share_requests r
        where r.status='approved' and 'messages'=any(r.requested_permissions) and(
          (r.requester_property_id=v_property_id and r.target_property_id=e.property_id)
          or(not v_is_owner and r.target_property_id=v_property_id and r.requester_property_id=e.property_id))))
  )q;
 return v_recipients;
end $function$;

create function omg_private.staff_schedule_targets(p_actor jsonb,p_peer text) returns text[] language plpgsql set search_path='' as $$
declare targets text[];gid uuid;begin
 if p_peer like 'group:%' then
  gid:=split_part(p_peer,':',2)::uuid;
  if not exists(select 1 from omg_private.staff_group_people(gid) where actor_key=p_actor->>'key') then raise exception '참여 중인 단체 채팅방이 아닙니다.';end if;
  select array_agg(actor_key order by actor_key) into targets from omg_private.staff_group_people(gid) where actor_key<>p_actor->>'key';
 else
  select array_agg(j->>'recipient_key') into targets from jsonb_array_elements(omg_private.staff_schedule_recipients(p_actor)) j where j->>'recipient_key'=p_peer;
 end if;
 if coalesce(cardinality(targets),0)=0 then raise exception '현재 이 대화에 메시지를 보낼 권한이 없습니다.';end if;
 return targets;
end$$;

create function omg_private.staff_schedule_rpc(p_access_token uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='40s' as $$
declare a jsonb;actor text;target_peer text:=p_data->>'peer';j omg_private.staff_scheduled_messages%rowtype;
 targets text[];client uuid;new_mode text;due timestamptz;employee uuid;baseline uuid;bytes bytea;mime text;preview bytea;items jsonb;people jsonb;begin
 a:=omg_private.guest_actor(p_access_token);actor:=a->>'key';
 if actor is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 if target_peer is null or target_peer!~'^(owner|employee|group):[0-9a-f-]{36}$' then raise exception '대화를 확인해주세요.';end if;
 if p_action not in('list','create','update','cancel') then raise exception '지원하지 않는 예약 요청입니다.';end if;
 -- Always take the employee lock before a job lock, matching report completion.
 if p_action in('create','update') and p_data->>'mode'='checkin' then
  perform 1 from public.employees where id=nullif(p_data->>'trigger_employee_id','')::uuid for update;
 end if;
 if p_action in('update','cancel') then
  select * into j from omg_private.staff_scheduled_messages s where s.id=(p_data->>'id')::uuid and s.actor_key=actor and s.peer=target_peer for update;
  if not found then raise exception '본인이 예약한 메시지만 변경할 수 있습니다.';end if;
  if j.status not in('pending','failed') or j.revision is distinct from (p_data->>'revision')::int then raise exception '이미 처리되었거나 변경된 예약입니다. 목록을 새로 확인해주세요.';end if;
 end if;
 if p_action='cancel' then
  update omg_private.staff_scheduled_messages set status='cancelled',attachment_bytes=null,preview_bytes=null,revision=revision+1,updated_at=clock_timestamp() where id=j.id;
 elsif p_action in('create','update') then
  targets:=omg_private.staff_schedule_targets(a,target_peer);
  if length(btrim(coalesce(p_data->>'body',''))) not between 1 and 2000 or coalesce(p_data->>'priority','normal') not in('normal','urgent') then raise exception '메시지 내용을 1~2,000자로 입력해주세요.';end if;
  new_mode:=p_data->>'mode';due:=nullif(p_data->>'send_at','')::timestamptz;employee:=nullif(p_data->>'trigger_employee_id','')::uuid;
  if new_mode='time' then
   if due is null or due<=clock_timestamp() or due>clock_timestamp()+interval '1 year' then raise exception '예약 시간은 현재 이후부터 1년 이내로 선택해주세요.';end if;
   employee:=null;
  elsif new_mode='checkin' then
   due:=null;
   if employee is null or not ('employee:'||employee=any(targets)) then raise exception '받는 근무자 중 출근 기준을 선택해주세요.';end if;
   -- Serialize arming with report completion, without retaining a login token.
   select id into baseline from public.work_sessions where employee_id=employee and checkin_report_at is not null order by checkin_report_at desc limit 1;
  else raise exception '예약 방식을 선택해주세요.';end if;
  if p_action='create' then
   client:=(p_data->>'client_id')::uuid;if client is null then raise exception '예약 식별자가 필요합니다.';end if;
   perform pg_advisory_xact_lock(hashtextextended(actor,39));
   if coalesce((p_data->>'uploaded')::boolean,false) then
    select image_bytes,mime_type into bytes,mime from omg_private.staff_chat_uploaded_attachment(actor,client,target_peer);
   else select image_bytes,mime_type into bytes,mime from omg_private.decode_staff_attachment(p_data->>'photo');end if;
   select * into j from omg_private.staff_scheduled_messages s where s.actor_key=actor and s.client_id=client;
   if found then
    if j.attachment_hash is distinct from md5(bytes) or j.peer<>target_peer or j.priority<>coalesce(p_data->>'priority','normal') or j.body<>btrim(p_data->>'body') or j.mode<>new_mode or j.send_at is distinct from due or j.trigger_employee_id is distinct from employee then raise exception '예약 식별자가 중복되었습니다.';end if;
   else
    if (select count(*) from omg_private.staff_scheduled_messages where actor_key=actor and status='pending')>=100 then raise exception '예약 메시지는 100개까지 보관할 수 있습니다.';end if;
    if p_data->>'preview' is not null then select image_bytes into preview from omg_private.decode_staff_attachment(p_data->>'preview');end if;
    insert into omg_private.staff_scheduled_messages(actor_key,client_id,property_id,peer,body,priority,mode,send_at,trigger_employee_id,baseline_session,attachment_hash,attachment_bytes,attachment_mime,preview_bytes)
     values(actor,client,(a->>'property_id')::uuid,target_peer,btrim(p_data->>'body'),coalesce(p_data->>'priority','normal'),new_mode,due,employee,baseline,md5(bytes),bytes,mime,preview) returning * into j;
   end if;
  else
   update omg_private.staff_scheduled_messages set body=btrim(p_data->>'body'),priority=coalesce(p_data->>'priority','normal'),mode=new_mode,send_at=due,trigger_employee_id=employee,
    baseline_session=baseline,ready_at=null,armed_at=clock_timestamp(),status='pending',error=null,revision=revision+1,updated_at=clock_timestamp() where id=j.id;
  end if;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') into items from(
  select s.id,s.body,s.priority,s.mode,s.send_at,s.trigger_employee_id,e.display_name trigger_name,s.status,s.revision,s.attachment_mime,s.error,s.created_at
  from omg_private.staff_scheduled_messages s left join public.employees e on e.id=s.trigger_employee_id where s.actor_key=actor and s.peer=target_peer and s.status in('pending','failed') order by s.created_at limit 100)x;
 begin targets:=omg_private.staff_schedule_targets(a,target_peer);exception when sqlstate 'P0001' then targets:='{}'::text[];end;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',display_name) order by display_name),'[]') into people from public.employees where 'employee:'||id=any(targets);
 return jsonb_build_object('ok',true,'id',j.id,'items',items,'recipients',people,'timezone',(select timezone from public.properties where id=(a->>'property_id')::uuid));
end$$;
create function public.staff_chat_schedule(p_access_token uuid,p_action text,p_data jsonb default '{}') returns jsonb language sql security definer set search_path='' as $$select omg_private.staff_schedule_rpc(p_access_token,p_action,p_data)$$;
revoke all on function public.staff_chat_schedule(uuid,text,jsonb) from public;
grant execute on function public.staff_chat_schedule(uuid,text,jsonb) to anon,authenticated,service_role;

create function omg_private.staff_schedule_report_ready() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.checkin_report_at is not null and (tg_op='INSERT' or old.checkin_report_at is null) and new.status='working' then
  perform 1 from public.employees where id=new.employee_id for update;
  update omg_private.staff_scheduled_messages set ready_at=clock_timestamp(),updated_at=clock_timestamp()
   where status='pending' and mode='checkin' and trigger_employee_id=new.employee_id and ready_at is null and baseline_session is distinct from new.id;
 end if;
 return new;
end$$;
create trigger staff_schedule_report_ready after insert or update of checkin_report_at on public.work_sessions for each row execute function omg_private.staff_schedule_report_ready();

create function omg_private.staff_schedule_run() returns void language plpgsql security definer set search_path='' as $$
declare j omg_private.staff_scheduled_messages%rowtype;a jsonb;targets text[];mid uuid;gid uuid;business uuid;begin
 for j in select * from omg_private.staff_scheduled_messages where status='pending' and ((mode='time' and send_at<=clock_timestamp()) or (mode='checkin' and ready_at is not null)) order by coalesce(send_at,ready_at),id for update skip locked limit 100 loop
  begin
   a:=omg_private.staff_schedule_actor(j.actor_key);
   if a is null or (a->>'property_id')::uuid<>j.property_id then raise exception '발신 계정이 비활성화되었거나 지점이 변경되었습니다.';end if;
   targets:=omg_private.staff_schedule_targets(a,j.peer);
   if j.mode='checkin' and not ('employee:'||j.trigger_employee_id=any(targets)) then raise exception '출근 기준 근무자가 더 이상 이 대화의 수신자가 아닙니다.';end if;
   select business_id into business from public.properties where id=j.property_id;
   gid:=case when j.peer like 'group:%' then split_part(j.peer,':',2)::uuid end;
   insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,sender_employee_id,message,priority,message_type,source,require_signature,require_understanding)
    values(business,j.property_id,a->>'kind',case when a->>'kind'='owner' then (a->>'id')::uuid end,case when a->>'kind'='staff' then (a->>'id')::uuid end,j.body,j.priority,'general',case when gid is not null then 'staff_group_chat' end,false,false) returning id into mid;
   if gid is not null then insert into omg_private.staff_group_messages values(mid,gid,false);end if;
   insert into omg_private.staff_chat_sends(actor_key,client_id,peer,body,priority,message_id) values(j.actor_key,j.id,j.peer,j.body,j.priority,mid);
   if j.attachment_bytes is not null then insert into omg_private.staff_chat_photos(message_id,image_bytes,mime_type,preview_bytes) values(mid,j.attachment_bytes,j.attachment_mime,j.preview_bytes);end if;
   insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id,employee_id)
    select mid,t,case when t like 'owner:%' then 'owner' else 'staff' end,case when t like 'owner:%' then split_part(t,':',2)::uuid end,case when t like 'employee:%' then split_part(t,':',2)::uuid end from unnest(targets)t;
   update omg_private.staff_scheduled_messages set status='sent',message_id=mid,error=null,attachment_bytes=null,preview_bytes=null,revision=revision+1,updated_at=clock_timestamp() where id=j.id;
  exception when others then
   update omg_private.staff_scheduled_messages set status='failed',error=case when sqlstate='P0001' then left(sqlerrm,200) else '예약 메시지를 발송하지 못했습니다. 수신자와 권한을 확인해주세요.' end,revision=revision+1,updated_at=clock_timestamp() where id=j.id;
  end;
 end loop;
end$$;
revoke all on function omg_private.staff_schedule_actor(text),omg_private.staff_schedule_recipients(jsonb),omg_private.staff_schedule_targets(jsonb,text),omg_private.staff_schedule_rpc(uuid,text,jsonb),omg_private.staff_schedule_report_ready(),omg_private.staff_schedule_run() from public,anon,authenticated;
select cron.schedule('oms-staff-scheduled-messages','* * * * *','select omg_private.staff_schedule_run()');
commit;
