-- The two opt-ins are independent of the QR channel. Enabling never replays old messages.
alter table omg_private.ai_settings add column online_enabled boolean not null default false,
 add column online_enabled_at timestamptz;
alter table omg_private.online_connections drop constraint online_connections_ai_mode_check,
 add constraint online_connections_ai_mode_check check(ai_mode in ('off','approval','automatic')),
 add column ai_automatic_at timestamptz;

create function omg_private.online_ai_mode_timestamp() returns trigger
language plpgsql set search_path='' as $$
begin
 if new.ai_mode<>'automatic' then
  new.ai_automatic_at:=null;
 elsif tg_op='INSERT' or old.ai_mode is distinct from new.ai_mode
    or old.beds_property_id is distinct from new.beds_property_id
    or old.vault_id is distinct from new.vault_id then
  new.ai_automatic_at:=clock_timestamp();
 end if;
 return new;
end $$;
create trigger online_ai_mode_timestamp before insert or update on omg_private.online_connections
 for each row execute function omg_private.online_ai_mode_timestamp();

create function omg_private.online_ai_eligible(p_property uuid,p_booking bigint,p_message bigint)
returns boolean language sql stable set search_path='' as $$
 select exists(
  select 1 from omg_private.online_connections c
  join omg_private.ai_settings s using(property_id)
  join public.properties p on p.id=c.property_id
  join omg_private.online_bookings b on b.property_id=c.property_id and b.id=p_booking
  join omg_private.online_messages m on m.property_id=c.property_id and m.booking_id=b.id and m.id=p_message
  where c.property_id=p_property and c.ai_mode='automatic' and c.vault_id is not null
   and c.beds_property_id is not null and s.online_enabled and m.source='guest'
   and b.status in ('new','confirmed','request','inquiry')
   and m.attachment_name is null and length(btrim(m.body))>0
   and s.online_enabled_at is not null and c.ai_automatic_at is not null
   and m.sent_at>=greatest(s.online_enabled_at,c.ai_automatic_at,now()-interval '15 minutes')
   and case s.mode
    when 'always' then true
    when 'no_staff' then not exists(
     select 1 from public.work_sessions w join public.employees e on e.id=w.employee_id
     where w.property_id=c.property_id and e.active and w.status='working'
      and w.checkin_report_at is not null and w.checkout_report_at is null and w.token_expires_at>now()
    )
    when 'schedule' then case when s.start_time<s.end_time
     then (now() at time zone p.timezone)::time>=s.start_time and (now() at time zone p.timezone)::time<s.end_time
     else (now() at time zone p.timezone)::time>=s.start_time or (now() at time zone p.timezone)::time<s.end_time end
    else false end
 );
$$;

do $migration$
declare definition text; anchor text; begin
 definition:=pg_get_functiondef('omg_private.ai_owner(uuid,text,jsonb)'::regprocedure);
 anchor:='  update omg_private.ai_settings set handoff_config=';
 if strpos(definition,anchor)=0 then raise exception 'Missing AI settings save';end if;
 definition:=replace(definition,anchor,$replace$
  if coalesce((p_data->>'online_enabled')::boolean,(select online_enabled from omg_private.ai_settings where property_id=home),false)
     and not exists(select from jsonb_array_elements(rows) j where btrim(coalesce(j->>'answer',''))<>'') then
   raise exception '자동답변 DATA를 하나 이상 입력해주세요.';
  end if;
  update omg_private.ai_settings set
   online_enabled_at=case when not coalesce((p_data->>'online_enabled')::boolean,online_enabled) then null
      when not online_enabled then clock_timestamp() else online_enabled_at end,
   online_enabled=coalesce((p_data->>'online_enabled')::boolean,online_enabled),
   handoff_config=$replace$);
 execute definition;

 definition:=pg_get_functiondef('omg_private.online_owner(uuid,text,jsonb)'::regprocedure);
 anchor:=$original$if coalesce(p_data->>'ai_mode','off') not in('off','approval') then raise exception '현재는 승인 후 발송 모드만 지원합니다.';end if;$original$;
 if strpos(definition,anchor)=0 then raise exception 'Missing online mode validation';end if;
 execute replace(definition,anchor,$replace$if coalesce(p_data->>'ai_mode','off') not in('off','approval','automatic') then raise exception '온라인 메시지 AI 응대 방식을 확인해주세요.';end if;$replace$);

 definition:=pg_get_functiondef('omg_private.online_internal(text,uuid,jsonb)'::regprocedure);
 anchor:=$original$if x is null or x->>'source'<>'guest' then return jsonb_build_object('skip',true);end if;mid:=(x->>'id')::bigint;$original$;
 if strpos(definition,anchor)=0 then raise exception 'Missing online draft selection';end if;
 definition:=replace(definition,anchor,anchor||$extra$
  if p_data->>'actor'='ai:automatic' and not omg_private.online_ai_eligible(p_property,bid,mid) then
   return jsonb_build_object('skip',true);
  end if;
$extra$);
 anchor:=$original$ elsif p_action='draft_finish' then$original$;
 if strpos(definition,anchor)=0 then raise exception 'Missing online draft finish';end if;
 execute replace(definition,anchor,$replace$
 elsif p_action='prepare_auto_reply' then
  bid:=(p_data->>'booking_id')::bigint;
  -- Use the same booking lock as the manual send path.
  perform pg_advisory_xact_lock(hashtextextended(p_property::text||':'||bid,909));
  select * into d from omg_private.online_outbox
   where property_id=p_property and booking_id=bid and id=(p_data->>'id')::uuid for update;
  if not found or d.kind<>'ai' or d.actor is distinct from 'ai:automatic' or d.status<>'draft'
   or d.result->>'disposition' is distinct from 'answer'
   or coalesce(d.result->>'alert_kind','none')<>'none'
   or length(btrim(d.body)) not between 1 and 4000 then
   return jsonb_build_object('skip',true);
  end if;
  if not omg_private.online_ai_eligible(p_property,bid,d.based_on)
   or d.result->>'data_revision' is distinct from (select revision::text from omg_private.ai_settings where property_id=p_property)
   or d.based_on is distinct from (select id from omg_private.online_messages where property_id=p_property and booking_id=bid order by sent_at desc,id desc limit 1)
   or exists(select 1 from omg_private.online_outbox other
      where other.property_id=p_property and other.booking_id=bid and other.id<>d.id
       and (other.status='sending' or other.status in ('sent','uncertain') and
            other.updated_at>=(select sent_at from omg_private.online_messages where property_id=p_property and id=d.based_on))) then
   return jsonb_build_object('skip',true);
  end if;
  update omg_private.online_outbox set status='sending',approved_by='ai:automatic',updated_at=now() where id=d.id;
  return jsonb_build_object('ok',true,'body',d.body);
 elsif p_action='draft_finish' then$replace$);
end $migration$;

revoke all on function omg_private.online_ai_mode_timestamp(),omg_private.online_ai_eligible(uuid,bigint,bigint) from public,anon,authenticated;
