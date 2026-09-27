-- Return each account's saved guest-chat delivery mode to its property owner.
begin;
create or replace function public.get_guest_chat_alert_modes(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare home uuid;modes jsonb;
begin
 select o.property_id into home
 from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token)
 and s.token_expires_at>clock_timestamp() and o.active;
 if home is null then raise exception '관리자 로그인이 필요합니다.';end if;
 select coalesce(jsonb_object_agg(n.actor_key,n.alert_mode),'{}'::jsonb) into modes
 from public.guest_chat_alert_preferences n where n.home_property_id=home;
 return jsonb_build_object('ok',true,'modes',modes);
end$$;
revoke all on function public.get_guest_chat_alert_modes(uuid) from public;
grant execute on function public.get_guest_chat_alert_modes(uuid) to anon,authenticated;
commit;
