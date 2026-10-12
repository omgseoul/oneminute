create table if not exists omg_private.android_signing_requests(
 token_hash text primary key,run_id text not null,commit_sha text not null,created_at timestamptz not null default now());
alter table omg_private.android_signing_requests enable row level security;revoke all on omg_private.android_signing_requests from public,anon,authenticated;
create or replace function public.android_signing_material(p_jti text,p_run_id text,p_commit_sha text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare material jsonb;
begin
 if char_length(p_jti) not between 1 and 200 or p_run_id !~ '^\d+$' or p_commit_sha !~ '^[0-9a-f]{40}$' then raise exception 'Invalid build';end if;
 insert into omg_private.android_signing_requests(token_hash,run_id,commit_sha) values(encode(sha256(convert_to(p_jti,'UTF8')),'hex'),p_run_id,p_commit_sha);
 select decrypted_secret::jsonb into material from vault.decrypted_secrets where name='oms_android_release_signing';
 if material is null then raise exception 'Signing key is not configured';end if;
 return material;
end$$;
revoke all on function public.android_signing_material(text,text,text) from public,anon,authenticated;
grant execute on function public.android_signing_material(text,text,text) to service_role;
