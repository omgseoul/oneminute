alter table public.properties add column if not exists contract_business_info jsonb not null default '{}';
alter table public.employment_contracts add column if not exists contract_fields jsonb not null default '{}';
alter table public.employment_contracts add column if not exists contract_ready boolean not null default false;

-- Existing OMS sessions are custom tokens, validated inside this narrow gateway.
create or replace function public.contract_business_info(p_access_token uuid,p_property_id uuid,p_action text default 'get',p_info jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare info jsonb;
begin
 if not exists(select 1 from public.owner_sessions s join public.owners o on o.id=s.owner_id where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active)
 or not coalesce(omg_private.can_manage_shared_property(p_access_token,p_property_id,'property_settings'),false) then raise exception '사업장 정보 접근 권한이 없습니다.';end if;
 if p_action='save' then
 if jsonb_typeof(p_info)<>'object' or length(p_info::text)>4000 then raise exception '사업장 정보를 확인해주세요.';end if;
 info:=jsonb_build_object('business_name',left(btrim(coalesce(p_info->>'business_name','')),100),'employer_name',left(btrim(coalesce(p_info->>'employer_name','')),100),'phone',left(btrim(coalesce(p_info->>'phone','')),50),'address',left(btrim(coalesce(p_info->>'address','')),500));
 update public.properties set contract_business_info=info where id=p_property_id;
 elsif p_action<>'get' then raise exception '지원하지 않는 요청입니다.';end if;
 select contract_business_info into info from public.properties where id=p_property_id;
 return jsonb_build_object('ok',true,'info',info);
end $$;
revoke all on function public.contract_business_info(uuid,uuid,text,jsonb) from public;
grant execute on function public.contract_business_info(uuid,uuid,text,jsonb) to anon,authenticated,service_role;

create or replace function public.employment_contract_rpc(p_access_token uuid,p_action text,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare own uuid;emp uuid;actor text;prop uuid;business uuid;eid uuid;cid uuid;tid uuid;mid uuid;c public.employment_contracts%rowtype;result jsonb;items jsonb;defaults jsonb;sig text;is_manager boolean;
begin
 select s.owner_id into own from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if own is null then
 select s.employee_id into emp from public.work_sessions s join public.employees e on e.id=s.employee_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and e.active and s.status in('working','completed');
 end if;
 if own is null and emp is null then raise exception '로그인이 만료되었습니다. 다시 로그인해주세요.';end if;
 actor:=case when own is not null then 'owner:'||own else 'employee:'||emp end;
 if p_action in('list','template_save','draft') then
 eid:=coalesce(nullif(p_data->>'employee_id','')::uuid,emp);
 select e.property_id,p.business_id into prop,business from public.employees e join public.properties p on p.id=e.property_id where e.id=eid and e.role<>'owner';
 is_manager:=own is not null and coalesce(omg_private.can_manage_shared_property(p_access_token,prop,'account_settings'),false);
 if prop is null or not coalesce(is_manager or (emp=eid and p_action='list'),false) then raise exception '계약서 접근 권한이 없습니다.';end if;
 if p_action='list' then
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'title',x.title,'status',x.status,'created_at',x.created_at,'signed_at',x.signed_at,'viewed_at',x.viewed_at,'version',x.version,'contract_ready',x.contract_ready) order by x.created_at desc),'[]') into items from public.employment_contracts x where x.employee_id=eid and (is_manager or x.status<>'draft');
 if is_manager then
 select jsonb_build_object('name',e.display_name,'job',e.job_title,'contact',e.contact_phone,'property',p.name,'clock_in',e.scheduled_clock_in,'clock_out',e.scheduled_clock_out,'pay_type',s.pay_type,'hourly_rate',s.hourly_rate,'monthly_salary',s.monthly_salary,'pay_day',s.pay_day,'business_info',p.contract_business_info) into defaults from public.employees e join public.properties p on p.id=e.property_id left join public.employee_payroll_settings s on s.employee_id=e.id where e.id=eid;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.updated_at desc),'[]') into result from public.employment_contract_templates t where t.property_id=prop;
 end if;
 return jsonb_build_object('ok',true,'contracts',items,'templates',coalesce(result,'[]'),'defaults',defaults,'can_manage',is_manager);
 elsif p_action='template_save' then
 tid:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());
 insert into public.employment_contract_templates(id,property_id,name,content) values(tid,prop,btrim(p_data->>'name'),p_data->>'content')
 on conflict(id) do update set name=excluded.name,content=excluded.content,updated_at=clock_timestamp() where employment_contract_templates.property_id=prop;
 if not found then raise exception '양식 저장 권한이 없습니다.';end if;
 return jsonb_build_object('ok',true,'id',tid);
 elsif p_action='draft' then
 if jsonb_typeof(coalesce(p_data->'contract_fields','{}'::jsonb))<>'object' or length(coalesce(p_data->'contract_fields','{}'::jsonb)::text)>30000 then raise exception '계약 항목을 확인해주세요.';end if;
 cid:=(p_data->>'id')::uuid;if cid is null then raise exception '계약서 번호가 필요합니다.';end if;
 perform pg_advisory_xact_lock(hashtextextended(cid::text,0));
 select * into c from public.employment_contracts where id=cid for update;
 if found then
 if c.employee_id<>eid or c.status<>'draft' or c.version<>coalesce((p_data->>'version')::integer,0) then raise exception '계약서가 변경되었습니다. 다시 열어주세요.';end if;
 update public.employment_contracts set title=btrim(p_data->>'title'),content=p_data->>'content',employer_name=btrim(coalesce(p_data->>'employer_name','')),contract_fields=coalesce(p_data->'contract_fields','{}'::jsonb),contract_ready=coalesce((p_data->>'contract_ready')::boolean,false),version=version+1,updated_at=clock_timestamp() where id=cid returning * into c;
 else
 insert into public.employment_contracts(id,property_id,employee_id,owner_id,title,content,employer_name,employee_name,property_name,contract_fields,contract_ready)
 select cid,prop,eid,own,btrim(p_data->>'title'),p_data->>'content',btrim(coalesce(p_data->>'employer_name','')),e.display_name,p.name,coalesce(p_data->'contract_fields','{}'::jsonb),coalesce((p_data->>'contract_ready')::boolean,false) from public.employees e join public.properties p on p.id=e.property_id where e.id=eid returning * into c;
 end if;
 return jsonb_build_object('ok',true,'contract',to_jsonb(c),'can_manage',true);
 end if;
 end if;
 cid:=(p_data->>'id')::uuid;
 select * into c from public.employment_contracts where id=cid for update;
 if not found then raise exception '계약서를 찾을 수 없습니다.';end if;
 is_manager:=own is not null and coalesce(omg_private.can_manage_shared_property(p_access_token,c.property_id,'account_settings'),false);
 if not coalesce(is_manager or (emp=c.employee_id and c.status<>'draft'),false) then raise exception '계약서 접근 권한이 없습니다.';end if;
 select business_id into business from public.properties where id=c.property_id;
 if p_action='get' then
 if emp=c.employee_id and c.status='sent' and c.viewed_at is null then
 update public.employment_contracts set viewed_at=clock_timestamp() where id=cid returning * into c;
 insert into public.employment_contract_events(contract_id,actor_key,event) values(cid,actor,'viewed');end if;
 return jsonb_build_object('ok',true,'contract',to_jsonb(c),'can_manage',is_manager);
 elsif p_action='send' then
 if not is_manager then raise exception '관리자만 서명을 요청할 수 있습니다.';end if;
 if c.status='sent' and c.version=(p_data->>'version')::integer then return jsonb_build_object('ok',true,'contract',to_jsonb(c),'message_id',c.message_id,'duplicate',true);end if;
 if c.status<>'draft' or c.version is distinct from (p_data->>'version')::integer then raise exception '최신 작성 중 계약서에서 발송해주세요.';end if;
 if length(c.employer_name) not between 1 and 100 or c.content~'\{\{|【입력】' then raise exception '사업주 이름과 계약서의 입력 항목을 모두 채워주세요.';end if;
 sig:=p_data->>'signature';if sig is null or sig!~'^data:image/png;base64,[A-Za-z0-9+/=]+$' or length(sig) not between 150 and 200000 then raise exception '사업주 서명을 입력해주세요.';end if;
 if not coalesce((p_data->>'confirmed')::boolean,false) then raise exception '계약 내용을 확인해주세요.';end if;
 insert into public.property_messages(business_id,property_id,sender_type,sender_owner_id,message,priority,message_type)
 values(business,c.property_id,'owner',own,'[근태관리] '||c.title||E'\n계약 내용을 확인하고 서명해주세요.\n[OMS-CONTRACT:'||cid||']','normal','general') returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,employee_id) values(mid,'employee:'||c.employee_id,'staff',c.employee_id);
 update public.employment_contracts set owner_id=own,status='sent',employer_signature=sig,content_hash=encode(sha256(convert_to(title||E'\n'||content||E'\n'||employer_name||E'\n'||employee_name||E'\n'||sig,'UTF8')),'hex'),sent_at=clock_timestamp(),updated_at=clock_timestamp(),message_id=mid where id=cid returning * into c;
 elsif p_action='cancel' then
 if not is_manager or c.status not in('draft','sent','revision_requested') then raise exception '취소할 수 없는 계약서입니다.';end if;
 update public.employment_contracts set status='cancelled',updated_at=clock_timestamp() where id=cid returning * into c;
 elsif p_action='request_change' then
 if emp is distinct from c.employee_id or c.status<>'sent' then raise exception '수정을 요청할 수 없습니다.';end if;
 if length(btrim(coalesce(p_data->>'reason',''))) not between 1 and 1000 then raise exception '수정 요청 내용을 입력해주세요.';end if;
 update public.employment_contracts set status='revision_requested',change_reason=btrim(p_data->>'reason'),updated_at=clock_timestamp() where id=cid returning * into c;
 insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type)
 values(business,c.property_id,'staff',emp,c.title||E'\n계약서 수정 요청: '||c.change_reason||E'\n[OMS-CONTRACT:'||cid||']','normal','general') returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id) values(mid,'owner:'||c.owner_id,'owner',c.owner_id);
 elsif p_action='sign' then
 if emp is distinct from c.employee_id then raise exception '계약 당사자만 서명할 수 있습니다.';end if;
 if c.status='signed' then return jsonb_build_object('ok',true,'contract',to_jsonb(c),'message_id',c.completion_message_id,'duplicate',true);end if;
 if c.status<>'sent' or c.content_hash is distinct from p_data->>'content_hash' or c.version is distinct from (p_data->>'version')::integer then raise exception '서명 요청이 변경되었거나 취소되었습니다. 다시 열어주세요.';end if;
 if not coalesce((p_data->>'confirmed')::boolean,false) then raise exception '내용 확인 및 전자서명 동의가 필요합니다.';end if;
 sig:=p_data->>'signature';if sig is null or sig!~'^data:image/png;base64,[A-Za-z0-9+/=]+$' or length(sig) not between 150 and 200000 then raise exception '서명을 입력해주세요.';end if;
 insert into public.property_messages(business_id,property_id,sender_type,sender_employee_id,message,priority,message_type)
 values(business,c.property_id,'staff',emp,c.title||E'\n서명이 완료되었습니다. 완료 계약서를 확인하세요.\n[OMS-CONTRACT:'||cid||']','normal','general') returning id into mid;
 insert into public.property_message_recipients(message_id,recipient_key,recipient_type,owner_id) values(mid,'owner:'||c.owner_id,'owner',c.owner_id);
 update public.employment_contracts set employee_signature=sig,status='signed',signed_at=clock_timestamp(),updated_at=clock_timestamp(),completion_message_id=mid where id=cid returning * into c;
 else raise exception '지원하지 않는 계약서 요청입니다.';
 end if;
 insert into public.employment_contract_events(contract_id,actor_key,event) values(cid,actor,p_action);
 return jsonb_build_object('ok',true,'contract',to_jsonb(c),'message_id',mid,'can_manage',is_manager);
end $$;
revoke all on function public.employment_contract_rpc(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.employment_contract_rpc(uuid,text,jsonb) to service_role;
