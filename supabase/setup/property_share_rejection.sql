-- Recipient administrators can reject pending property access requests.
-- Lock the same row used by approve_property_share so the first decision wins.
begin;
create or replace function public.reject_property_share(p_access_token uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid;v_property_id uuid;v_request public.property_share_requests%rowtype;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id
  from public.owner_sessions s join public.owners o on o.id=s.owner_id and o.property_id=s.property_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;
  if not found then return jsonb_build_object('ok',false,'code','owner_required','message','관리자만 결재할 수 있습니다.'); end if;
  select * into v_request from public.property_share_requests
  where id=p_request_id and target_property_id=v_property_id for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found','message','공유 요청을 찾을 수 없습니다.'); end if;
  if v_request.status='rejected' then return jsonb_build_object('ok',true,'status','rejected','already_rejected',true); end if;
  if v_request.status<>'pending' then return jsonb_build_object('ok',false,'code','not_pending','message','이미 처리된 공유 요청입니다.'); end if;
  update public.property_share_requests set status='rejected',approved_at=null,approved_by=null where id=v_request.id;
  update public.property_message_recipients r set read_at=coalesce(r.read_at,clock_timestamp())
  from public.property_messages m
  where r.message_id=m.id and m.property_share_request_id=v_request.id and r.owner_id=v_owner_id;
  return jsonb_build_object('ok',true,'status','rejected');
end;
$$;
revoke all on function public.reject_property_share(uuid,uuid) from public;
grant execute on function public.reject_property_share(uuid,uuid) to anon,authenticated;
commit;
