-- Owner sessions are application-managed, but the browser may also have a
-- Supabase Auth session. Both PostgREST roles must be able to invoke the
-- token-validated owner RPC.
begin;

grant execute on function public.owner_message_storage(uuid,text,jsonb) to anon,authenticated;

commit;
