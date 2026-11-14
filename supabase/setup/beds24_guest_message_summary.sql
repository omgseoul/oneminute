-- Preserve the existing filter/period API and count the same paged rows as the inbox.
-- Keep native application badges independent of the current inbox filters.
begin;
CREATE OR REPLACE FUNCTION omg_private.guest_message_summary(p_access_token uuid, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 a jsonb:=omg_private.guest_actor(p_access_token);home uuid;f jsonb:=coalesce(p_data->'filters','{}');period jsonb:=p_data->'period';
 ids uuid[];states jsonb;stay jsonb;d jsonb;prop uuid;tz text;day date;lo date;hi date;days int:=7;
 page jsonb;rows jsonb;off int;n bigint:=0;threads bigint:=0;messenger bigint;
begin
 if a is null then raise exception '직원 로그인이 필요합니다.';end if;home:=(a->>'property_id')::uuid;
 select coalesce(timezone,'Asia/Seoul') into tz from public.properties where id=home;day:=(now() at time zone tz)::date;
 -- These defaults match the dedicated guest page (including the QR filter migration).
 states:=case when jsonb_typeof(f->'statuses')='array' then f->'statuses' else '["new","confirmed","request","inquiry","qr"]'::jsonb end;
 if coalesce((f->>'qrVersion')::int,0)<>1 and not states?'qr' then states:=states||'"qr"'::jsonb;end if;
 stay:=case when jsonb_typeof(f->'stayTypes')='array' and not exists(select 1 from jsonb_array_elements_text(f->'stayTypes') x where x not in('checkin','staying','checkout','other')) then f->'stayTypes' else '["checkin","staying","checkout","other"]'::jsonb end;
 if jsonb_typeof(f->'properties')='array' then
  select coalesce(array_agg(p.id),'{}'::uuid[]) into ids from public.properties p where p.id::text in(select jsonb_array_elements_text(f->'properties')) and omg_private.guest_can_access(home,p.id);
  if jsonb_array_length(f->'properties')>0 and cardinality(ids)=0 then ids:=array[home];end if;
 else ids:=array[home];end if;
 if jsonb_typeof(period)='object' then
  if (period->>'days')~'^[0-9]+$' and (period->>'days')::numeric between 1 and 3650 then days:=(period->>'days')::int;
  elsif period->>'days'='0' and (period->>'from')~'^\d{4}-\d{2}-\d{2}$' and (period->>'to')~'^\d{4}-\d{2}-\d{2}$' and period->>'to'>=period->>'from' then days:=0;lo:=(period->>'from')::date;hi:=(period->>'to')::date;end if;
 end if;
 if days>0 then lo:=day-(days-1);hi:=day;end if;
 d:=jsonb_build_object('statuses',states-'qr','stay_types',stay,'direction',case when f->>'direction' in('all','guest','host') then f->>'direction' else 'all' end,'unread_only',coalesce((f->>'unreadOnly')::boolean,false),'unreplied_only',coalesce((f->>'unrepliedOnly')::boolean,false),'message_from',lo,'message_to',hi);
 foreach prop in array ids loop
  select coalesce(timezone,'Asia/Seoul') into tz from public.properties where id=prop;
  off:=0;
  loop
   page:=omg_private.online_inbox_followup(prop,'inbox',d||jsonb_build_object('offset',off),tz);rows:=page->'threads';
   select n+coalesce(sum((r->>'unread')::bigint),0),threads+count(*) into n,threads from jsonb_array_elements(rows) r;
   exit when jsonb_array_length(rows)<300 or off>=14700;off:=off+300;
  end loop;
  if states?'qr' then
   off:=0;
   loop
    page:=omg_private.guest_message_inbox(p_access_token,d||jsonb_build_object('property_id',prop,'offset',off));rows:=page->'threads';
    select n+coalesce(sum((r->>'unread')::bigint),0),threads+count(*) into n,threads from jsonb_array_elements(rows) r;
    exit when jsonb_array_length(rows)<300 or off>=15000;off:=off+300;
   end loop;
  end if;
 end loop;
 select count(*) into messenger from public.property_message_recipients r join public.property_messages m on m.id=r.message_id where r.recipient_key=a->>'key' and r.read_at is null and coalesce(m.source,'')<>'beds24' and coalesce(m.message_type,'')<>'guest_chat';
 return jsonb_build_object('ok',true,'unread',n,'threads',threads,'messenger_unread',messenger,'total_unread',omg_private.guest_message_unread(p_access_token)->'unread');
end$function$
;
CREATE OR REPLACE FUNCTION public.guest_message_summary(p_access_token uuid, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$select omg_private.guest_message_summary(p_access_token,p_data)$function$
;
revoke all on function public.guest_message_summary(uuid,jsonb),omg_private.guest_message_summary(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.guest_message_summary(uuid,jsonb) to anon,authenticated,service_role;
grant execute on function omg_private.guest_message_summary(uuid,jsonb) to service_role;
commit;

