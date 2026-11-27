create function public.staff_account_quota(p_access_token uuid,p_property_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$begin
 if not coalesce(omg_private.can_manage_shared_property(p_access_token,p_property_id,'account_settings'),false) then raise exception '계정관리 권한이 필요합니다.';end if;
 return (select jsonb_build_object('limit',coalesce(sp.employee_limit,10),'count',(select count(*) from public.employees e where e.property_id=p.id and e.active and e.role<>'owner'))
 from public.properties p left join omg_private.service_plans sp on sp.code=p.service_plan where p.id=p_property_id);
end$$;
revoke all on function public.staff_account_quota(uuid,uuid) from public;
grant execute on function public.staff_account_quota(uuid,uuid) to anon,authenticated;

create function omg_private.iot_notice_context(p_message uuid,p_property uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('channel',b.channel,'reference',b.data->>'apiReference','booking_id',b.id)
 from omg_private.iot_notices n join omg_private.iot_jobs j on j.id=n.job_id
 join omg_private.online_bookings b on b.property_id=j.property_id and b.id=j.booking_id
 where n.message_id=p_message and j.property_id=p_property
$$;
revoke all on function omg_private.iot_notice_context(uuid,uuid) from public,anon,authenticated;
do $migration$ declare def text;signature text;needle text:=$n$'message_id',m.id,'property_id',m.property_id,$n$;begin
 for signature in select unnest(array['public.list_property_messages(uuid)','public.list_notification_bot_messages(uuid,timestamptz,uuid)']) loop
  def:=pg_get_functiondef(signature::regprocedure);
  if strpos(def,needle)=0 then raise exception 'Missing message metadata hook';end if;
  execute replace(def,needle,needle||$n$'iot_booking',case when v_is_owner and m.source='iot_lock' then omg_private.iot_notice_context(m.id,m.property_id) else null end,$n$);
 end loop;
 def:=pg_get_functiondef('omg_private.iot_notice(uuid,text)'::regprocedure);
 needle:=$n$||E'\n숙박: '$n$;
 if strpos(def,needle)=0 then raise exception 'Missing IOT notice hook';end if;
 execute replace(def,needle,$n$||E'\n예약사이트: '||coalesce(nullif(b.channel,''),'미확인')||E'\n사이트 예약번호: '||coalesce(nullif(b.data->>'apiReference',''),'-')||E'\nBeds24 예약번호: '||j.booking_id$n$||needle);
end$migration$;
