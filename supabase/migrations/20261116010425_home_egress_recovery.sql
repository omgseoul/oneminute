begin;
-- Keep inbox filters and authorization identical; never ship profiles/history for badges.
create or replace function public.home_message_summary(
 p_access_token uuid,p_data jsonb default '{}',p_revision text default null,p_include_alerts boolean default false
) returns jsonb language plpgsql security definer set search_path='' set statement_timeout='12s' as $$
declare a jsonb:=omg_private.guest_actor(p_access_token);g jsonb;rev text;alerts jsonb;
 reports jsonb:='[]';report_count bigint:=0;since_at timestamptz;answer jsonb;
begin
 if a is null then return jsonb_build_object('ok',false,'code','invalid_session');end if;
 g:=omg_private.guest_message_summary(p_access_token,p_data);
 if not coalesce((g->>'ok')::boolean,false) then return g;end if;
 if a->>'kind'='owner' then
  select started_at into since_at from omg_private.report_inbox_started where id;
  select count(*) into report_count from public.work_reports r
  where r.submitted_at>=since_at and omg_private.guest_can_access((a->>'property_id')::uuid,r.property_id)
   and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(a->>'id')::uuid);
  if p_include_alerts then
   select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]') into reports from (
    select r.id,r.submitted_at,jsonb_build_object('report_id',r.id,'report_type',r.report_type,'employee_name',coalesce(r.payload->>'worker',e.display_name),'unread',true) item
    from public.work_reports r join public.employees e on e.id=r.employee_id
    where r.submitted_at>=since_at and omg_private.guest_can_access((a->>'property_id')::uuid,r.property_id)
     and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(a->>'id')::uuid)
    order by r.submitted_at desc,r.id desc limit 50
   )x;
  end if;
 end if;
 answer:=jsonb_build_object('ok',true,'can_manage',a->>'kind'='owner','guest_unread',g->'unread',
  'messenger_unread',g->'messenger_unread','report_unread',report_count,
  'staff_unread',coalesce((g->>'messenger_unread')::bigint,0)+report_count);
 if not p_include_alerts then return answer;end if;
 -- Includes read/ack changes: a stable count alone cannot identify a new arrival.
 select md5(coalesce(string_agg(x.state,'|' order by x.created_at,x.id),'')) into rev from (
  select m.id,m.created_at,concat_ws(':',m.id,r.read_at,r.acknowledged_at,md5(m.message),m.priority,m.source) state
  from public.property_message_recipients r join public.property_messages m on m.id=r.message_id
  where r.recipient_key=a->>'key' order by m.created_at desc,m.id desc limit 150
 )x;
 answer:=answer||jsonb_build_object('revision',rev,'messages_changed',rev is distinct from p_revision,'reports',reports);
 if rev is distinct from p_revision then
  -- The established inbox supplies popup eligibility and shared-branch context.
  -- This expensive projection runs only after a change, never for native badge reads.
  select coalesce(jsonb_agg(item-'announcement_acknowledgements'-'recipient_labels' order by ord),'[]') into alerts
  from jsonb_array_elements(public.list_property_messages(p_access_token)->'messages') with ordinality t(item,ord)
  where not coalesce((item->>'is_sender')::boolean,false) and item->>'read_at' is null;
  answer:=answer||jsonb_build_object('messages',alerts);
 end if;
 return answer;
end $$;
revoke all on function public.home_message_summary(uuid,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function public.home_message_summary(uuid,jsonb,text,boolean) to anon,authenticated,service_role;
alter table omg_private.staff_chat_photos add column if not exists preview_bytes bytea;
alter table omg_private.staff_chat_photos drop constraint if exists staff_chat_preview_size;
alter table omg_private.staff_chat_photos add constraint staff_chat_preview_size check(preview_bytes is null or octet_length(preview_bytes) between 3 and 65536);
-- Old clients retain their API. New clients opt out before large JPEG encoding occurs.
do $$declare name text;definition text;needle text:=$n$when f.mime_type='image/jpeg' then$n$;
begin
 foreach name in array array['omg_private.staff_chat_core(uuid,text,jsonb)','omg_private.staff_group_rpc(uuid,text,jsonb)'] loop
  definition:=pg_get_functiondef(name::regprocedure);
  if position('metadata_only' in definition)=0 then
   if position(needle in definition)=0 then raise exception 'Photo projection changed: %',name;end if;
   definition:=replace(definition,needle,$r$when f.mime_type='image/jpeg' and not coalesce((p_data->>'metadata_only')::boolean,false) then$r$);
   execute definition;
  end if;
 end loop;
end $$;
create or replace function public.staff_chat_compact(p_access_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' set statement_timeout='40s' as $$
declare result jsonb;a jsonb:=omg_private.guest_actor(p_access_token);preview bytea;mid uuid;
begin
 if a is null then raise exception '로그인이 만료되었습니다.';end if;
 if p_action='preview' then
  -- Reuse the attachment's direct/group membership and leave-history authorization.
  perform omg_private.staff_chat_download(p_access_token,'download_info',p_data);
  return jsonb_build_object('ok',true,'preview',(select case when preview_bytes is not null then 'data:image/jpeg;base64,'||replace(encode(preview_bytes,'base64'),chr(10),'') end from omg_private.staff_chat_photos where message_id=(p_data->>'message_id')::uuid));
 end if;
 if p_action not in('messages','send') then raise exception '잘못된 요청입니다.';end if;
 if p_action='send' and p_data->>'preview' is not null then
  if length(p_data->>'preview')>87500 or p_data->>'preview' !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$' then raise exception '미리보기 형식을 확인해주세요.';end if;
  preview:=decode(split_part(p_data->>'preview',',',2),'base64');
  if octet_length(preview) not between 3 and 65536 or substring(preview from 1 for 3)<>decode('ffd8ff','hex') then raise exception '미리보기 크기를 확인해주세요.';end if;
 end if;
 result:=public.staff_chat_rpc(p_access_token,p_action,p_data||jsonb_build_object('metadata_only',true));
 if p_action='send' and coalesce((result->>'ok')::boolean,false) and preview is not null then
  mid:=(result->>'message_id')::uuid;
  update omg_private.staff_chat_photos f set preview_bytes=coalesce(f.preview_bytes,preview)
  where f.message_id=mid and exists(select 1 from public.property_messages m where m.id=mid and
   ((a->>'kind'='owner' and m.sender_owner_id=(a->>'id')::uuid) or (a->>'kind'='staff' and m.sender_employee_id=(a->>'id')::uuid)));
 end if;
 if p_action='messages' then
  result:=jsonb_set(result,'{messages}',coalesce((select jsonb_agg((item-'photo')||jsonb_build_object('photo',
   (select case when f.preview_bytes is not null then 'data:image/jpeg;base64,'||replace(encode(f.preview_bytes,'base64'),chr(10),'') end from omg_private.staff_chat_photos f where f.message_id=(item->>'id')::uuid),'photo_is_preview',true) order by ord)
   from jsonb_array_elements(result->'messages') with ordinality t(item,ord)),'[]'));
 end if;
 return result;
end $$;
revoke all on function public.staff_chat_compact(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.staff_chat_compact(uuid,text,jsonb) to anon,authenticated,service_role;

notify pgrst, 'reload schema';
commit;
