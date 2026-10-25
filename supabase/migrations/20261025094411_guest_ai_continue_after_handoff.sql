-- A request needing staff attention must not mute unrelated later questions.
-- ai_handoff retains the unresolved staff queue; ai_paused controls automation.
alter table public.guest_chat_rooms add column ai_paused boolean not null default false;
comment on column public.guest_chat_rooms.ai_paused is 'AI paused for urgent or explicit human-only handling. Separate from unresolved staff attention.';

-- Preserve active emergency / explicit human requests. Ordinary model handoffs resume.
update public.guest_chat_rooms r set ai_paused=true
where r.ai_handoff and exists (
 select 1 from omg_private.ai_alerts a where a.room_id=r.id
 and (a.urgent or a.reason='게스트가 직원 연결을 요청했습니다.')
 and a.created_at>coalesce((select max(m.created_at) from public.guest_chat_messages m where m.room_id=r.id and m.sender_kind='ai' and exists(select 1 from omg_private.ai_jobs j where j.id=m.client_id and j.status='completed')),'-infinity'::timestamptz)
);

-- Patch only the gates; preserve all tenant auth, accounting and unresolved-message logic.
do $migration$
declare spec record; definition text;
begin
 for spec in select * from (values
  ('omg_private.ai_enqueue()','not r.ai_handoff','not r.ai_paused'),
  ('omg_private.ai_claim()','r.ai_handoff','r.ai_paused'),
  ('omg_private.ai_finish(uuid,uuid,jsonb)','r.ai_handoff','r.ai_paused'),
  ('omg_private.ai_alert(uuid,uuid,boolean,text)','set ai_handoff=true,updated_at=now()','set ai_handoff=true,ai_paused=ai_paused or p_urgent,updated_at=now()'),
  ('omg_private.ai_room_action(text,jsonb,uuid,uuid)','set ai_handoff=false,assigned_key=null','set ai_handoff=false,ai_paused=false,assigned_key=null'),
  ('omg_private.ai_room_action(text,jsonb,uuid,uuid)', 'else raise exception ''지원하지 않는 요청입니다.'';end if;', 'update public.guest_chat_rooms set ai_paused=true where id=r.id;
 else raise exception ''지원하지 않는 요청입니다.'';end if;'),
  ('public.guest_support_rpc(text,jsonb,uuid,uuid,text)', '''ai_handoff'',room.ai_handoff,''ai_active'',omg_private.ai_active(room.property_id) and room.assigned_key is null and not room.ai_handoff', '''ai_handoff'',room.ai_handoff,''ai_paused'',room.ai_paused,''ai_active'',omg_private.ai_active(room.property_id) and room.assigned_key is null and not room.ai_paused')
 ) as patches(signature,before_text,after_text)
 loop
  definition:=pg_get_functiondef(spec.signature::regprocedure);
  if strpos(definition,spec.before_text)=0 then raise exception 'AI continuation patch target changed: %',spec.signature;end if;
  execute replace(definition,spec.before_text,spec.after_text);
 end loop;
end
$migration$;
