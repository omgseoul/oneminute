-- Platform-only, manually confirmed retention. No records are deleted by installation.
begin;
create table if not exists public.message_cleanup_jobs(
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references auth.users(id),
 property_id uuid not null references public.properties(id), months integer not null check(months in(3,6,9,12)),
 cutoff timestamptz not null, categories text[] not null, message_ids uuid[] not null default '{}',
 chat_ids uuid[] not null default '{}', asset_ids uuid[] not null default '{}',
 summary jsonb not null, status text not null default 'preview' check(status in('preview','pending','complete')),
 created_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists public.message_cleanup_files(
 asset_id uuid primary key, job_id uuid not null references public.message_cleanup_jobs(id),
 object_path text not null, deleted_at timestamptz);
alter table public.message_cleanup_jobs enable row level security;
alter table public.message_cleanup_files enable row level security;
revoke all on public.message_cleanup_jobs,public.message_cleanup_files from public,anon,authenticated;

create or replace function omg_private.guest_asset_bytes(p_path text) returns bigint
language plpgsql security definer set search_path='' as $$declare n bigint;begin
 if to_regclass('storage.objects') is null then return 0;end if;
 execute 'select coalesce((metadata->>''size'')::bigint,0) from storage.objects where bucket_id=''guest-support'' and name=$1' into n using p_path;
 return coalesce(n,0);
end$$;
revoke all on function omg_private.guest_asset_bytes(text) from public,anon,authenticated;

create or replace function public.platform_message_storage(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare prop uuid; months int; cutoff timestamptz; cats text[]; mid uuid[];cid uuid[];aid uuid[];result jsonb;j public.message_cleanup_jobs%rowtype;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then raise exception 'OMG WORKS 운영자만 사용할 수 있습니다.';end if;
 if p_action='usage' then
 select coalesce(jsonb_agg(to_jsonb(x) order by x.property_name),'[]') into result from(
 select p.id property_id,p.name property_name,p.management_number,
 (select count(*) from public.guest_chat_rooms r where r.property_id=p.id) rooms,
 (select count(*) from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where r.property_id=p.id) chat_count,
 (select coalesce(sum(octet_length(m.body)),0) from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where r.property_id=p.id) chat_bytes,
 (select count(*) from public.property_messages m where m.property_id=p.id) message_count,
 (select coalesce(sum(octet_length(m.message)),0) from public.property_messages m where m.property_id=p.id) message_bytes,
 (select count(*) from public.guest_support_assets a where a.property_id=p.id and a.room_id is not null) chat_photo_count,
 (select coalesce(sum(omg_private.guest_asset_bytes(a.object_path)),0) from public.guest_support_assets a where a.property_id=p.id and a.room_id is not null) chat_photo_bytes,
 (select coalesce(sum(omg_private.guest_asset_bytes(a.object_path)),0) from public.guest_support_assets a where a.property_id=p.id and a.room_id is null) guide_bytes,
 0 message_photo_count,0 message_photo_bytes
 from public.properties p)x;
 return jsonb_build_object('ok',true,'properties',result,'pending_jobs',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'property_id',property_id,'summary',summary)),'[]') from public.message_cleanup_jobs where status='pending'));
 elsif p_action='preview' then
 prop:=(p_data->>'property_id')::uuid;months:=(p_data->>'months')::int;
 if months is null or months not in(3,6,9,12) or not exists(select 1 from public.properties where id=prop) then raise exception '숙소와 보관 기간을 선택해주세요.';end if;
 select array_agg(value) into cats from jsonb_array_elements_text(p_data->'categories');
 if cardinality(cats) is null or cardinality(cats)=0 or not cats<@array['chat','messages','chat_photos','message_photos'] then raise exception '정리 항목을 선택해주세요.';end if;
 cutoff:=now()-make_interval(months=>months);
 select coalesce(array_agg(m.id),'{}') into mid from public.property_messages m where m.property_id=prop and m.created_at<cutoff and 'messages'=any(cats);
 select coalesce(array_agg(m.id),'{}') into cid from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where r.property_id=prop and m.created_at<cutoff and 'chat'=any(cats);
 select coalesce(array_agg(a.id),'{}') into aid from public.guest_support_assets a where a.property_id=prop and a.room_id is not null and a.created_at<cutoff and 'chat_photos'=any(cats)
 and not exists(select 1 from public.guest_chat_messages m where m.asset_id=a.id and m.created_at>=cutoff)
 and not exists(select 1 from public.message_cleanup_files f where f.asset_id=a.id);
 result:=jsonb_build_object('property_name',(select name from public.properties where id=prop),'cutoff',cutoff,'chat_count',cardinality(cid),'message_count',cardinality(mid),'chat_photo_count',cardinality(aid),'message_photo_count',0,'photo_bytes',(select coalesce(sum(omg_private.guest_asset_bytes(a.object_path)),0) from public.guest_support_assets a where a.id=any(aid)));
 insert into public.message_cleanup_jobs(actor_id,property_id,months,cutoff,categories,message_ids,chat_ids,asset_ids,summary) values(auth.uid(),prop,months,cutoff,cats,mid,cid,aid,result) returning * into j;
 return jsonb_build_object('ok',true,'job_id',j.id,'summary',result);
 elsif p_action='execute' then
 select * into j from public.message_cleanup_jobs where id=(p_data->>'job_id')::uuid and actor_id=auth.uid() for update;
 if not found then raise exception '삭제 요청을 확인할 수 없습니다.';end if;
 if j.status<>'preview' then return jsonb_build_object('ok',true,'job_id',j.id,'status',j.status);end if;
 if j.created_at<now()-interval '10 minutes' then raise exception '미리보기가 만료되었습니다. 다시 조회해주세요.';end if;
 if p_data->>'confirm_name' is distinct from j.summary->>'property_name' then raise exception '숙소명을 정확히 입력해주세요.';end if;
 -- Lock selected attachments and exclude any that acquired a newer reference since preview.
 perform 1 from public.guest_support_assets where id=any(j.asset_ids) for update;
 select coalesce(array_agg(a.id),'{}') into aid from public.guest_support_assets a where a.id=any(j.asset_ids) and a.property_id=j.property_id
 and not exists(select 1 from public.guest_chat_messages m where m.asset_id=a.id and m.created_at>=j.cutoff);
 update public.guest_support_assets set ready=false where id=any(aid);
 insert into public.message_cleanup_files(asset_id,job_id,object_path) select id,j.id,object_path from public.guest_support_assets where id=any(aid) on conflict do nothing;
 update public.guest_chat_messages set asset_id=null,body=case when body='' then '[삭제된 사진]' else body end where asset_id=any(aid);
 delete from public.property_messages where id=any(j.message_ids) and property_id=j.property_id and created_at<j.cutoff;
 delete from public.guest_chat_events where message_id=any(j.chat_ids);
 delete from public.guest_chat_messages where id=any(j.chat_ids) and asset_id is null and created_at<j.cutoff;
 update public.guest_chat_messages set body='' where id=any(j.chat_ids) and asset_id is not null and created_at<j.cutoff;
 update public.message_cleanup_jobs set status=case when cardinality(aid)>0 then 'pending' else 'complete' end,completed_at=case when cardinality(aid)=0 then now() end where id=j.id returning * into j;
 return jsonb_build_object('ok',true,'job_id',j.id,'status',j.status);
 end if;
 raise exception '지원하지 않는 요청입니다.';
end$$;
revoke all on function public.platform_message_storage(text,jsonb) from public,anon;
grant execute on function public.platform_message_storage(text,jsonb) to authenticated;

-- The Edge function verifies the JWT with Auth before supplying p_user; never callable by clients.
create or replace function public.platform_message_storage_worker(p_user uuid,p_job uuid,p_done uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$declare result jsonb;begin
 if not omg_private.is_platform_administrator(p_user) then raise exception '운영자 권한이 필요합니다.';end if;
 perform 1 from public.message_cleanup_jobs where id=p_job and status in('pending','complete') for update;
 if not found then raise exception '삭제 작업을 확인해주세요.';end if;
 delete from public.guest_support_assets a using public.message_cleanup_files f where f.asset_id=a.id and f.job_id=p_job and f.asset_id=any(p_done) and f.deleted_at is null;
 update public.message_cleanup_files set deleted_at=now() where job_id=p_job and asset_id=any(p_done) and deleted_at is null;
 if not exists(select 1 from public.message_cleanup_files where job_id=p_job and deleted_at is null) then
 update public.message_cleanup_jobs set status='complete',completed_at=now() where id=p_job;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from(select asset_id,object_path from public.message_cleanup_files where job_id=p_job and deleted_at is null order by asset_id limit 50)x;
 return jsonb_build_object('ok',true,'files',result,'status',(select status from public.message_cleanup_jobs where id=p_job));
end$$;
revoke all on function public.platform_message_storage_worker(uuid,uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.platform_message_storage_worker(uuid,uuid,uuid[]) to service_role;

-- Serializes attachment reuse against manual retention; protects newer messages during cleanup.
create or replace function omg_private.guest_attachment_ready() returns trigger language plpgsql security definer set search_path='' as $$declare allowed boolean;begin
 if new.asset_id is not null then select ready into allowed from public.guest_support_assets where id=new.asset_id for share;
 if not coalesce(allowed,false) then raise exception '사진을 다시 첨부해주세요.';end if;end if;return new;end$$;
drop trigger if exists guest_attachment_ready on public.guest_chat_messages;
create trigger guest_attachment_ready before insert or update of asset_id on public.guest_chat_messages for each row execute function omg_private.guest_attachment_ready();
commit;
