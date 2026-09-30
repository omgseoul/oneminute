-- Run after deploying guest-email and adding its four secrets. This does NOT enable sending.
-- Store the SAME GUEST_EMAIL_WORKER_SECRET in Vault as omg_guest_email_worker_secret
-- using the Dashboard Vault form; never commit it to SQL or put it in browser JS.
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
-- Final activation after the domain is verified for BOTH sending and receiving:
-- update public.guest_email_config set enabled=true where singleton;
-- Emergency stop (webchat itself keeps working):
-- update public.guest_email_config set enabled=false where singleton;
