-- Individual profiles for self and current co-members; unrelated actors remain forbidden.
CREATE OR REPLACE FUNCTION public.staff_chat_peer_profile(p_access_token uuid, p_peer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor jsonb;
  current_actor_key text;
  is_allowed boolean:=false;
  profile jsonb;
begin
  actor:=omg_private.guest_actor(p_access_token);
  current_actor_key:=actor->>'key';
  if current_actor_key is null then
    return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다. 다시 로그인해주세요.');
  end if;
  if p_peer like 'group:%' then return omg_private.staff_group_rpc(p_access_token,'profile',jsonb_build_object('peer',p_peer));end if;
  if p_peer is null or p_peer!~'^(owner|employee):[0-9a-f-]{36}$' then
    return jsonb_build_object('ok',false,'code','invalid_peer','message','대화 상대를 확인해주세요.');
  end if;

  select p_peer=current_actor_key or exists(
    select 1 from jsonb_array_elements(coalesce(public.list_property_messages(p_access_token)->'recipients','[]'::jsonb)) recipient
    where recipient->>'recipient_key'=p_peer
  ) or exists(
    select 1 from omg_private.staff_conversation_items(current_actor_key) item where item.peer=p_peer
  ) or exists(
    select 1 from omg_private.staff_group_members mine
    join omg_private.staff_group_members person on person.group_id=mine.group_id
    where mine.actor_key=current_actor_key and mine.left_at is null
      and person.actor_key=p_peer and person.left_at is null
  ) into is_allowed;

  if not is_allowed then
    return jsonb_build_object('ok',false,'code','forbidden','message','이 대화 상대의 정보를 볼 수 없습니다.');
  end if;

  if p_peer like 'employee:%' then
    select jsonb_build_object(
      'kind','employee','display_name',e.display_name,'profile_image',e.profile_image,
      'job_title',coalesce(e.job_title,''),'property_name',p.name,'contact_phone',coalesce(e.contact_phone,'')
    ) into profile
    from public.employees e join public.properties p on p.id=e.property_id
    where e.id=substring(p_peer from 10)::uuid;
  else
    select jsonb_build_object(
      'kind','owner','display_name',o.display_name,'profile_image',o.profile_image,
      'job_title','관리자','property_name',p.name,'contact_phone',''
    ) into profile
    from public.owners o join public.properties p on p.id=o.property_id
    where o.id=substring(p_peer from 7)::uuid;
  end if;

  if profile is null then
    return jsonb_build_object('ok',false,'code','not_found','message','근무자 정보를 찾을 수 없습니다.');
  end if;
  return jsonb_build_object('ok',true,'profile',profile);
end;
$function$;
revoke all on function public.staff_chat_peer_profile(uuid,text) from public,anon,authenticated;
grant execute on function public.staff_chat_peer_profile(uuid,text) to anon,authenticated;
