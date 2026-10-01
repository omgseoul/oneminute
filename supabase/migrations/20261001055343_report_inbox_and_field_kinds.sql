-- Typed custom fields and a read-only report mailbox. Existing saves/attendance remain unchanged.
begin;
create or replace function omg_private.custom_report_fields_are_valid(p_fields jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
begin
 if p_fields is null or jsonb_typeof(p_fields)<>'array' then return false;end if;
 return jsonb_array_length(p_fields)<=20 and octet_length(p_fields::text)<=5000
 and not exists(select 1 from jsonb_array_elements(p_fields) item(value)
 where jsonb_typeof(item.value)<>'object' or coalesce(item.value->>'key','')!~'^custom_[a-z0-9_-]{1,50}$'
 or char_length(btrim(coalesce(item.value->>'label',''))) not between 1 and 40
 or (item.value ? 'kind' and (jsonb_typeof(item.value->'kind')<>'string' or item.value->>'kind' not in('text','numeric','counter','rooms','photo'))))
 and (select count(*)=count(distinct item.value->>'key') from jsonb_array_elements(p_fields)item(value));
end;$$;
revoke all on function omg_private.custom_report_fields_are_valid(jsonb) from public,anon,authenticated;

create or replace function public.work_report_inbox(p_access_token uuid,p_report_id uuid default null,p_before_at timestamptz default null,p_before_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor jsonb;items jsonb;
begin
 actor:=omg_private.guest_actor(p_access_token);
 if actor is null then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');end if;
 select coalesce(jsonb_agg(x.item order by x.submitted_at desc,x.id desc),'[]'::jsonb) into items from (
 select r.id,r.submitted_at,jsonb_build_object('report_id',r.id,'report_type',r.report_type,'submitted_at',r.submitted_at,
 'employee_name',coalesce(r.payload->>'worker',e.display_name),'profile_image',to_jsonb(e)->>'profile_image','property_name',p.name,
 'work_date',r.payload->>'work_date','edited',r.payload ? 'edited_at',
 'preview',left(coalesce(r.payload->>'memo',''),120),
 'payload',case when p_report_id is not null then r.payload else null end) item
 from public.work_reports r join public.employees e on e.id=r.employee_id join public.properties p on p.id=r.property_id
 where ((actor->>'kind'='owner' and omg_private.guest_can_access((actor->>'property_id')::uuid,r.property_id))
 or (actor->>'kind'='staff' and r.employee_id=(actor->>'id')::uuid and r.property_id=(actor->>'property_id')::uuid))
 and (p_report_id is null or r.id=p_report_id)
 and (p_before_at is null or (r.submitted_at,r.id)<(p_before_at,coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
 order by r.submitted_at desc,r.id desc limit 50
 )x;
 return jsonb_build_object('ok',true,'reports',items);
end;$$;
revoke all on function public.work_report_inbox(uuid,uuid,timestamptz,uuid) from public;
grant execute on function public.work_report_inbox(uuid,uuid,timestamptz,uuid) to anon,authenticated;
create index if not exists work_reports_property_submitted_idx on public.work_reports(property_id,submitted_at desc,id desc);
create index if not exists work_reports_employee_submitted_idx on public.work_reports(employee_id,submitted_at desc,id desc);
commit;
