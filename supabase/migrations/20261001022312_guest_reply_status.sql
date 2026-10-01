-- Read-only response metadata extension. All authorization and lifecycle branches remain byte-for-byte unchanged.
-- Assignment/close controls are removed in the UI; this migration does NOT disable them in the server.
do $migration$
declare definition text;old_rooms text;new_rooms text;old_room text;new_room text;
begin
 definition:=pg_get_functiondef('public.guest_support_rpc(text,jsonb,uuid,uuid,text)'::regprocedure);
 old_rooms:='r.assigned_name,r.updated_at,';
 new_rooms:='r.assigned_name,r.updated_at,
 (select min(g.created_at) from public.guest_chat_messages g where g.room_id=r.id and g.sender_kind=''guest'' and g.seq>coalesce((select max(s.seq) from public.guest_chat_messages s where s.room_id=r.id and s.sender_kind=''staff''),0)) unanswered_since,';
 old_room:='''status'',room.status,''property_name''';
 new_room:='''status'',room.status,''unanswered_since'',(select min(g.created_at) from public.guest_chat_messages g where g.room_id=roomid and g.sender_kind=''guest'' and g.seq>coalesce((select max(s.seq) from public.guest_chat_messages s where s.room_id=roomid and s.sender_kind=''staff''),0)),''property_name''';
 if position(old_rooms in definition)=0 or position(old_room in definition)=0 then raise exception 'Guest chat response anchors changed; no migration applied';end if;
 execute replace(replace(definition,old_rooms,new_rooms),old_room,new_room);
end $migration$;
