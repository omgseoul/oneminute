create or replace function omg_private.online_arrivals(p_token uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;begin
 -- Reuse the same property authorization as the cleaning booking list, including staff.
 a:=omg_private.online_owner(p_token,'auth',jsonb_build_object('property_id',p_data->>'property_id','request_action','bookings'));
 if p_action<>'read' and coalesce(omg_private.guest_actor(p_token)->>'kind','')<>'owner' then raise exception '도착예상 업데이트는 관리자만 가능합니다.';end if;
 if p_action<>'read' and not coalesce(omg_private.can_manage_shared_property(p_token,(a->>'property_id')::uuid,'property_settings'),false) then raise exception '이 지점의 관리자 설정 권한이 필요합니다.';end if;
 return omg_private.online_arrival_control((a->>'property_id')::uuid,p_action,p_data-'automatic');
end$$;
