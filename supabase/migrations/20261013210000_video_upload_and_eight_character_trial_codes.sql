-- Convert existing invitations; permit compressed To do videos and count their storage.
do $$
declare row_code record;new_code text;
begin
 for row_code in select id from omg_private.trial_codes where char_length(code)<>8 order by created_at,id loop
  loop
   new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
   exit when not exists(select 1 from omg_private.trial_codes as taken where taken.code=new_code);
  end loop;
  update omg_private.trial_codes set code=new_code where id=row_code.id;
 end loop;
end$$;
alter table omg_private.trial_codes drop constraint if exists trial_codes_code_check;
alter table omg_private.trial_codes add constraint trial_codes_code_check check(code ~ '^[A-Z0-9]{8}$');

create or replace function omg_private.property_usage_bytes(prop uuid) returns bigint language sql volatile security definer set search_path='' as $$
 select (select coalesce(sum(octet_length(payload::text)),0) from public.work_reports where property_id=prop)
 +(select coalesce(sum(octet_length(message)),0) from public.property_messages where property_id=prop)
 +(select coalesce(sum(octet_length(m.body)),0) from public.guest_chat_messages m join public.guest_chat_rooms r on r.id=m.room_id where r.property_id=prop)
 +(select coalesce(sum(omg_private.guest_asset_bytes(a.object_path)),0) from public.guest_support_assets a where a.property_id=prop)
 +(select coalesce(sum(coalesce((o.metadata->>'size')::bigint,0)),0) from storage.objects o join public.employees e on e.id=omg_private.document_employee(o.name) where o.bucket_id='employee-documents' and e.property_id=prop)
 +(select coalesce(sum(octet_length(coalesce(c.photo_data_url,''))+octet_length(coalesce(c.note,''))),0) from public.mission_completions c join public.missions m on m.id=c.mission_id where m.property_id=prop)
 +(select coalesce(sum(octet_length(coalesce(m.description_photo,''))),0) from public.missions m where m.property_id=prop)
 +(select coalesce(sum(octet_length(e.report_config::text)),0) from public.employees e where e.property_id=prop);
$$;

create or replace function omg_private.guard_service_write() returns trigger language plpgsql security definer set search_path='' as $$
declare prop uuid;s jsonb;delta bigint:=0;has_photo boolean:=false;before_bytes bigint:=0;
begin
 if tg_table_schema='public' and tg_table_name='property_messages' then
  if new.sender_type='system' and new.source='platform_system' and exists(select 1 from omg_private.system_notice_deliveries where message_id=new.id and property_id=new.property_id) then return new;end if;
 end if;
 if tg_table_schema='storage' then
 if new.bucket_id='guest-support' then select property_id into prop from public.guest_support_assets where object_path=new.name;
 elsif new.bucket_id='employee-documents' then select property_id into prop from public.employees where id=omg_private.document_employee(new.name);end if;
 if prop is null then return new;end if;has_photo:=true;delta:=coalesce((new.metadata->>'size')::bigint,0);if tg_op='UPDATE' then delta:=delta-coalesce((old.metadata->>'size')::bigint,0);end if;
 elsif tg_table_name='mission_completions' then select property_id into prop from public.missions where id=new.mission_id;
 elsif tg_table_name='guest_chat_messages' then select property_id into prop from public.guest_chat_rooms where id=new.room_id;
 else prop:=new.property_id;end if;
 perform 1 from public.properties where id=prop for update;
 s:=omg_private.property_service_state(prop);
 if coalesce((s->>'restricted')::boolean,false) then raise exception '이용 기간이 종료되었습니다. 관리자에게 구독 연장을 요청해주세요.';end if;
 if tg_table_name='missions' then has_photo:=coalesce(new.description_photo,'')<>'';delta:=octet_length(coalesce(new.description_photo,''));if tg_op='UPDATE' then delta:=delta-octet_length(coalesce(old.description_photo,''));end if;
 elsif tg_table_name='mission_completions' then has_photo:=coalesce(new.photo_data_url,'')<>'';delta:=octet_length(coalesce(new.photo_data_url,''));if tg_op='UPDATE' then delta:=delta-octet_length(coalesce(old.photo_data_url,''));end if;
 elsif tg_table_name='work_reports' then has_photo:=new.payload::text like '%data:image/%';delta:=octet_length(new.payload::text);if tg_op='UPDATE' then delta:=delta-octet_length(old.payload::text);end if;
 elsif tg_table_name='property_messages' then has_photo:=new.message like '%data:image/%';delta:=octet_length(new.message);if tg_op='UPDATE' then delta:=delta-octet_length(old.message);end if;end if;
 if has_photo and delta>0 and not(s->>'exempt')::boolean and s->>'storage_action'='block_photos' and (s->>'used_bytes')::bigint+delta>(s->>'limit_bytes')::bigint then raise exception '저장 용량을 초과했습니다. 관리자에게 용량 추가를 요청해주세요.';end if;
 return new;
end$$;

create or replace function public.check_trial_code(p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
declare c omg_private.trial_codes%rowtype;
begin
 if omg_private.normalize_trial_code(p_code) !~ '^[A-Z0-9]{8}$' then return jsonb_build_object('ok',false,'message','체험코드를 확인해주세요.');end if;
 select * into c from omg_private.trial_codes where code=omg_private.normalize_trial_code(p_code) and used_at is null and revoked_at is null and (expires_at is null or expires_at>now());
 if not found then return jsonb_build_object('ok',false,'message','사용 가능한 체험코드가 아닙니다. 코드를 확인하거나 운영자에게 문의해주세요.');end if;
 return jsonb_build_object('ok',true,'trial_days',c.trial_days,'storage_limit_bytes',c.storage_limit_bytes);
end$$;
revoke all on function public.check_trial_code(text) from public;
grant execute on function public.check_trial_code(text) to anon,authenticated;

create or replace function public.platform_trial_codes(p_action text default 'list',p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare n int;value text;days int;lim bigint;expiry timestamptz;items jsonb;c omg_private.trial_codes%rowtype;
begin
 if auth.uid() is null or not omg_private.is_platform_administrator(auth.uid()) then return jsonb_build_object('ok',false,'message','OMS 운영자 권한이 필요합니다.');end if;
 if p_action='create' then
  n:=coalesce((p_data->>'count')::int,1);if n not between 1 and 100 then raise exception '한 번에 1~100개를 생성할 수 있습니다.';end if;
  select coalesce((p_data->>'trial_days')::int,trial_days),coalesce((p_data->>'storage_limit_bytes')::bigint,storage_limit_bytes) into days,lim from omg_private.service_policy where id;
  expiry:=nullif(p_data->>'expires_at','')::timestamptz;
  if expiry is not null and expiry<=now() then raise exception '코드 만료일은 미래로 설정해주세요.';end if;
  if btrim(coalesce(p_data->>'code',''))<>'' and n<>1 then raise exception '직접 지정한 코드는 한 개씩 생성해주세요.';end if;
  for i in 1..n loop
   value:=omg_private.normalize_trial_code(nullif(btrim(p_data->>'code'),''));
   if value='' then loop value:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));exit when not exists(select 1 from omg_private.trial_codes as existing_code where existing_code.code=value);end loop;elsif value !~ '^[A-Z0-9]{8}$' then raise exception '체험코드는 영문 또는 숫자 8자리로 입력해주세요.';end if;
   insert into omg_private.trial_codes(code,trial_days,storage_limit_bytes,expires_at,note,created_by) values(value,days,lim,expiry,btrim(coalesce(p_data->>'note','')),auth.uid());
  end loop;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_codes_created',jsonb_build_object('count',n,'trial_days',days,'storage_limit_bytes',lim));
 elsif p_action='revoke' then
  update omg_private.trial_codes set revoked_at=now() where id=(p_data->>'id')::uuid and used_at is null and revoked_at is null;
  if not found then return jsonb_build_object('ok',false,'message','미사용 코드만 사용 중지할 수 있습니다.');end if;
  insert into public.platform_audit_logs(operator_user_id,action,detail) values(auth.uid(),'trial_code_revoked',jsonb_build_object('id',p_data->>'id'));
 elsif p_action<>'list' then raise exception '지원하지 않는 요청입니다.';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into items from(
  select tc.id,tc.code,tc.trial_days,tc.storage_limit_bytes,tc.expires_at,tc.note,tc.created_at,tc.used_at,tc.used_email,tc.registration_name,tc.registration_property_name,tc.property_id,p.name property_name,
   case when tc.used_at is not null then 'used' when tc.revoked_at is not null then 'revoked' when tc.expires_at<=now() then 'expired' else 'unused' end status
  from omg_private.trial_codes tc left join public.properties p on p.id=tc.property_id
 )x;
 return jsonb_build_object('ok',true,'codes',items);
end$$;
revoke all on function public.platform_trial_codes(text,jsonb) from public,anon;
grant execute on function public.platform_trial_codes(text,jsonb) to authenticated;

create or replace FUNCTION public.save_mission(p_access_token uuid, p_mission jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_business_id uuid;v_property_id uuid;v_employee_id uuid;v_id uuid;v_targets jsonb;v_due timestamptz;
  v_mode text;v_is_owner boolean:=false;v_priority text;v_description_photo text:=coalesce(p_mission->>'description_photo','');
begin
  select s.business_id,s.property_id into v_business_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
  if found then v_is_owner:=true;
  else
    select s.business_id,s.property_id,s.employee_id into v_business_id,v_property_id,v_employee_id
    from public.work_sessions s join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp()
      and e.active and s.status in('working','completed');
    if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.'); end if;
  end if;
  v_priority:=case when coalesce(p_mission->>'priority','normal') in('important','urgent') then 'important' else 'normal' end;
  if jsonb_typeof(p_mission)<>'object' or char_length(btrim(coalesce(p_mission->>'title',''))) not between 1 and 100
    or char_length(coalesce(p_mission->>'description',''))>2000 or octet_length(v_description_photo)>30000000
    or (v_description_photo<>'' and v_description_photo not like 'data:image/%' and v_description_photo not like 'data:video/webm;base64,%')
    or coalesce(p_mission->>'timing','') not in('today','this_week','anytime') then
    return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용과 첨부 파일을 확인해주세요.');
  end if;
  if v_is_owner then v_targets:=coalesce(p_mission->'target_employee_ids','[]'::jsonb);
  else
    if nullif(p_mission->>'id','') is not null then return jsonb_build_object('ok',false,'code','owner_required','message','직원은 새 미션만 등록할 수 있습니다.'); end if;
    v_targets:=jsonb_build_array(v_employee_id);
  end if;
  if jsonb_typeof(v_targets)<>'array' or jsonb_array_length(v_targets)>50
    or exists(select 1 from jsonb_array_elements_text(v_targets)x(value)
      where not exists(select 1 from public.employees e where e.id::text=x.value and e.property_id=v_property_id and e.active)) then
    return jsonb_build_object('ok',false,'code','invalid_target','message','담당 근무자를 확인해주세요.');
  end if;
  v_mode:=coalesce(p_mission->>'completion_mode','all');
  if v_mode not in ('all','any') or (v_mode='any' and (not v_is_owner or jsonb_array_length(v_targets)<>0)) then
    return jsonb_build_object('ok',false,'code','invalid_completion_mode','message','완료 방식을 확인해주세요.');
  end if;
  begin v_due:=nullif(p_mission->>'due_at','')::timestamptz;
  exception when others then return jsonb_build_object('ok',false,'code','invalid_due_at','message','마감일시를 확인해주세요.'); end;
  begin v_id:=nullif(p_mission->>'id','')::uuid;
  exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션을 확인해주세요.'); end;
  if v_id is null then
    insert into public.missions(business_id,property_id,title,description,description_photo,timing,priority,target_employee_ids,photo_required,estimated_minutes,due_at,creator_type,creator_employee_id,completion_mode)
    values(v_business_id,v_property_id,btrim(p_mission->>'title'),coalesce(p_mission->>'description',''),v_description_photo,p_mission->>'timing',v_priority,
      v_targets,coalesce((p_mission->>'photo_required')::boolean,false),30,v_due,case when v_is_owner then 'owner' else 'staff' end,v_employee_id,v_mode)
    returning id into v_id;
  else
    update public.missions set title=btrim(p_mission->>'title'),description=coalesce(p_mission->>'description',''),description_photo=v_description_photo,
      completion_mode=v_mode,timing=p_mission->>'timing',priority=v_priority,target_employee_ids=v_targets,
      photo_required=coalesce((p_mission->>'photo_required')::boolean,false),due_at=v_due,updated_at=clock_timestamp()
    where id=v_id and property_id=v_property_id and active and v_is_owner;
    if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  end if;
  return jsonb_build_object('ok',true,'mission_id',v_id);
exception when invalid_text_representation then return jsonb_build_object('ok',false,'code','invalid_mission','message','미션 내용을 확인해주세요.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_mission(p_access_token uuid, p_mission_id uuid, p_note text DEFAULT ''::text, p_photo_data_url text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_employee_id uuid; v_property_id uuid; v_mission public.missions%rowtype;
begin
  select s.employee_id,s.property_id into v_employee_id,v_property_id from public.work_sessions s join public.employees e on e.id=s.employee_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in ('working','completed');
  if not found then return jsonb_build_object('ok',false,'code','staff_required','message','근무자 로그인 후 완료할 수 있습니다.'); end if;
  select * into v_mission from public.missions where id=p_mission_id and property_id=v_property_id and active and (jsonb_array_length(target_employee_ids)=0 or target_employee_ids ? v_employee_id::text) for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','미션을 찾을 수 없습니다.'); end if;
  if v_mission.completion_mode='any' and exists(select 1 from public.mission_completions where mission_id=p_mission_id) then
    return jsonb_build_object('ok',false,'code','already_completed','message','이미 다른 근무자가 완료한 할일입니다.');
  end if;
  if v_mission.photo_required and btrim(coalesce(p_photo_data_url,''))='' then return jsonb_build_object('ok',false,'code','photo_required','message','완료 사진을 올려주세요.'); end if;
  if char_length(coalesce(p_note,''))>1000 or octet_length(coalesce(p_photo_data_url,''))>30000000 or (coalesce(p_photo_data_url,'')<>'' and p_photo_data_url not like 'data:image/%' and p_photo_data_url not like 'data:video/webm;base64,%') then return jsonb_build_object('ok',false,'code','too_large','message','메모 또는 첨부 파일 용량을 줄여주세요.'); end if;
  insert into public.mission_completions(mission_id,employee_id,note,photo_data_url) values(p_mission_id,v_employee_id,coalesce(p_note,''),coalesce(p_photo_data_url,'')) on conflict(mission_id,employee_id) do update set note=excluded.note,photo_data_url=excluded.photo_data_url,completed_at=clock_timestamp();
  return jsonb_build_object('ok',true);
end; $function$
;

