-- Serialize each worker's uploaded documents and generated contract PDFs under one quota.
create or replace function omg_private.document_employee(object_name text) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare result uuid;
begin
 if object_name like 'contracts/%' then
 select employee_id into result from public.employment_contracts where id=split_part(object_name,'/',2)::uuid;
 else result:=split_part(object_name,'/',2)::uuid;
 end if;
 return result;
exception when invalid_text_representation then return null;
end $$;
revoke all on function omg_private.document_employee(text) from public,anon,authenticated;
create or replace function omg_private.enforce_employee_document_quota() returns trigger
language plpgsql security definer set search_path='' as $$
declare employee uuid;used_bytes bigint;new_bytes bigint;
begin
 if new.bucket_id<>'employee-documents' then return new;end if;
 employee:=omg_private.document_employee(new.name);
 if employee is null then raise exception '문서 보관 대상을 확인해주세요.';end if;
 perform 1 from public.employees where id=employee for update;
 if not found then raise exception '문서 보관 대상을 확인해주세요.';end if;
 new_bytes:=coalesce((new.metadata->>'size')::bigint,0);
 if new_bytes>10485760 then raise exception '파일 한 개는 10MB 이하만 업로드할 수 있습니다.';end if;
 select coalesce(sum(coalesce((o.metadata->>'size')::bigint,0)),0) into used_bytes
 from storage.objects o where o.bucket_id='employee-documents' and o.id<>new.id
 and omg_private.document_employee(o.name)=employee;
 if used_bytes+new_bytes>52428800 then raise exception '문서보관함은 근무자별 총 50MB까지 사용할 수 있습니다. 불필요한 첨부 문서를 삭제한 후 다시 시도해주세요.';end if;
 return new;
end $$;
revoke all on function omg_private.enforce_employee_document_quota() from public,anon,authenticated;
create trigger employee_document_quota before insert or update of metadata,name,bucket_id on storage.objects
for each row execute function omg_private.enforce_employee_document_quota();
create or replace function public.employee_document_usage(p_access_token uuid,p_employee_id uuid) returns bigint
language plpgsql security definer set search_path='' as $$
declare used_bytes bigint;
begin
 if public.authorize_employee_documents(p_access_token,p_employee_id) is null then raise exception '문서 접근 권한이 없습니다.';end if;
 select coalesce(sum(coalesce((o.metadata->>'size')::bigint,0)),0) into used_bytes from storage.objects o
 where o.bucket_id='employee-documents' and omg_private.document_employee(o.name)=p_employee_id;
 return used_bytes;
end $$;
revoke all on function public.employee_document_usage(uuid,uuid) from public,anon,authenticated;
grant execute on function public.employee_document_usage(uuid,uuid) to service_role;
-- Expose storage readiness separately from signature completion.
do $$ declare definition text; begin
 select pg_get_functiondef('public.employment_contract_rpc(uuid,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'''contract_ready'',x.contract_ready)', '''contract_ready'',x.contract_ready,''pdf_ready'',x.pdf_path is not null)');
 execute definition;
end $$;
