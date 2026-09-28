-- Add a device-respecting weak guest-chat notification mode.
begin;

do $$
declare constraint_name text;
begin
  select c.conname into constraint_name
  from pg_constraint c
  where c.conrelid='public.guest_chat_alert_preferences'::regclass
    and c.contype='c'
    and pg_get_constraintdef(c.oid) like '%alert_mode%';
  if constraint_name is not null then
    execute format('alter table public.guest_chat_alert_preferences drop constraint %I',constraint_name);
  end if;
end$$;

alter table public.guest_chat_alert_preferences
  add constraint guest_chat_alert_preferences_alert_mode_check
  check(alert_mode in ('weak','normal','urgent'));

create or replace function public.save_guest_chat_alert_mode(p_access_token uuid,p_actor_key text,p_alert_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare home uuid;
begin
 if p_alert_mode not in ('weak','normal','urgent') then raise exception '알림 방식을 선택해주세요.';end if;
 select o.property_id into home from public.owner_sessions s join public.owners o on o.id=s.owner_id
 where s.login_token_hash=omg_private.token_hash(p_access_token) and s.token_expires_at>clock_timestamp() and o.active;
 if home is null then raise exception '관리자 로그인이 필요합니다.';end if;
 if not exists(select 1 from public.employees where 'employee:'||id=p_actor_key and property_id=home and active)
 and not exists(select 1 from public.owners where 'owner:'||id=p_actor_key and property_id=home and active)
 then raise exception '자기 지점 계정만 설정할 수 있습니다.';end if;
 update public.guest_chat_alert_preferences set alert_mode=p_alert_mode,updated_at=now()
 where actor_key=p_actor_key and home_property_id=home;
 if not found then raise exception '게스트 메세지 알림 설정을 먼저 저장해주세요.';end if;
 return jsonb_build_object('ok',true,'alert_mode',p_alert_mode);
end$$;
revoke all on function public.save_guest_chat_alert_mode(uuid,text,text) from public;
grant execute on function public.save_guest_chat_alert_mode(uuid,text,text) to anon,authenticated;

commit;
