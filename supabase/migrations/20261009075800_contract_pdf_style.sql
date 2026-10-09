alter table public.employment_contracts add column if not exists pdf_style text;

create or replace function omg_private.protect_signed_contract() returns trigger language plpgsql set search_path='' as $$
begin
 if old.status='signed' and (tg_op='DELETE' or (to_jsonb(new)-array['pdf_path','pdf_hash','pdf_style']) is distinct from (to_jsonb(old)-array['pdf_path','pdf_hash','pdf_style'])) then
 raise exception '서명 완료된 계약서는 변경하거나 삭제할 수 없습니다.';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
revoke all on function omg_private.protect_signed_contract() from public,anon,authenticated;
