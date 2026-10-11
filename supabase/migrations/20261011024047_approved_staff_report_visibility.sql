-- Explicitly approved: staff can read colleagues' reports within message-shared properties.
CREATE OR REPLACE FUNCTION public.work_report_inbox(p_access_token uuid, p_report_id uuid DEFAULT NULL::uuid, p_before_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor jsonb;items jsonb;unread_count bigint:=0;unread_by_property jsonb:='{}'::jsonb;since_at timestamptz;
begin
 actor:=omg_private.guest_actor(p_access_token);
 if actor is null then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 select started_at into since_at from omg_private.report_inbox_started where id;
 if actor->>'kind'='owner' then
   select count(*) into unread_count from public.work_reports r
   where r.submitted_at>=since_at and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id)
   and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid);
   select coalesce(jsonb_object_agg(x.property_id,x.total),'{}'::jsonb) into unread_by_property from (
     select r.property_id,count(*) total from public.work_reports r
     where r.submitted_at>=since_at and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id)
       and not exists(select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid)
     group by r.property_id
   )x;
 end if;
 select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]'::jsonb) into items from (
 select r.id,r.submitted_at,jsonb_build_object('report_id',r.id,'report_type',r.report_type,'submitted_at',r.submitted_at,
 'employee_name',coalesce(r.payload->>'worker',e.display_name),'profile_image',to_jsonb(e)->>'profile_image','property_name',p.name,'property_id',p.id,
 'work_date',r.payload->>'work_date','edited',r.payload ? 'edited_at',
 'preview',left(coalesce(r.payload->>'memo',''),120),
 'unread',actor->>'kind'='owner' and r.submitted_at>=since_at and not exists(
   select 1 from omg_private.work_report_reads rr where rr.report_id=r.id and rr.owner_id=(actor->>'id')::uuid),
 'payload',case when p_report_id is not null then r.payload else null end) item
 from public.work_reports r join public.employees e on e.id=r.employee_id join public.properties p on p.id=r.property_id
 where (actor->>'kind' in ('owner','staff') and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id))
 and (p_report_id is null or r.id=p_report_id)
 and (p_before_at is null or (r.submitted_at,r.id)<(p_before_at,coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
 order by r.submitted_at desc,r.id desc limit 50
 )x;
 return jsonb_build_object('ok',true,'reports',items,'unread_count',unread_count,'unread_by_property',unread_by_property);
end;$function$
;
