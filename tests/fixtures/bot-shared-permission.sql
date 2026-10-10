CREATE OR REPLACE FUNCTION omg_private.can_manage_shared_property(p_token uuid, p_property uuid, p_scope text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.owner_sessions s JOIN public.owners o ON o.id=s.owner_id
 WHERE s.login_token_hash=omg_private.token_hash(p_token) AND s.token_expires_at>clock_timestamp() AND o.active
 AND (s.property_id=p_property OR EXISTS(SELECT 1 FROM public.property_share_requests r WHERE r.requester_property_id=s.property_id AND r.target_property_id=p_property AND r.status='approved' AND p_scope=ANY(r.requested_permissions)))) $function$
