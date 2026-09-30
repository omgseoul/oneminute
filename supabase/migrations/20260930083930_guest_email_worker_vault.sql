-- Worker credentials stay encrypted in Vault. No client may verify or read them.
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$begin
 if not exists(select 1 from vault.secrets where name='omg_guest_email_worker_secret') then
  perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),
   'omg_guest_email_worker_secret','Internal guest email scheduler authentication');
 end if;
end$$;

create or replace function omg_private.verify_guest_email_worker(p_secret text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' or p_secret is null
  or p_secret !~ '^[a-f0-9]{64}$' then return false;end if;
 return exists(select 1 from vault.decrypted_secrets where name='omg_guest_email_worker_secret'
  and extensions.digest(convert_to(decrypted_secret,'UTF8'),'sha256')=
      extensions.digest(convert_to(p_secret,'UTF8'),'sha256'));
end$$;
revoke all on function omg_private.verify_guest_email_worker(text) from public,anon,authenticated;
grant usage on schema omg_private to service_role;
grant execute on function omg_private.verify_guest_email_worker(text) to service_role;
create or replace function public.verify_guest_email_worker(p_secret text)
returns boolean language sql security invoker set search_path='' as $$
 select omg_private.verify_guest_email_worker(p_secret);
$$;
revoke all on function public.verify_guest_email_worker(text) from public,anon,authenticated;
grant execute on function public.verify_guest_email_worker(text) to service_role;

-- A one-minute poll also retries safe failures. Activation is a separate operation.
select cron.schedule('omg-guest-email-dispatch','* * * * *',$job$
 select net.http_post(
  url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/guest-email/dispatch',
  headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',
   (select decrypted_secret from vault.decrypted_secrets where name='omg_guest_email_worker_secret')),
  body:='{}'::jsonb,timeout_milliseconds:=60000
 ) where exists(select 1 from public.guest_email_config where enabled);
$job$);
