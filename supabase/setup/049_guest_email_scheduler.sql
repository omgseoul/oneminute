-- Run after deploying guest-email and configuring SMTP. This does NOT enable sending.
-- The guest_email_worker_vault migration generates the encrypted worker token.
-- The Edge Function validates it through a service-role-only RPC; no duplicate
-- Edge Function secret is required. Legacy GUEST_EMAIL_WORKER_SECRET installs
-- must still use the same token in Vault. Never commit credentials to SQL.
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$begin
 if not exists(select 1 from vault.decrypted_secrets where name='omg_guest_email_worker_secret') then
  raise exception 'Add omg_guest_email_worker_secret to Vault first';
 end if;
end$$;
select cron.schedule('omg-guest-email-dispatch','* * * * *',$job$
 select net.http_post(
  url:='https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/guest-email/dispatch',
  headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',
   (select decrypted_secret from vault.decrypted_secrets where name='omg_guest_email_worker_secret')),
  body:='{}'::jsonb,timeout_milliseconds:=60000
 ) where exists(select 1 from public.guest_email_config where enabled);
$job$);
-- Final activation after SMTP and the reply link have been verified:
-- update public.guest_email_config set enabled=true where singleton;
-- Emergency stop (webchat itself keeps working):
-- update public.guest_email_config set enabled=false where singleton;
