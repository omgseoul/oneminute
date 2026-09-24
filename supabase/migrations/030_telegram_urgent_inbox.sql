-- Persist Telegram !! urgent alerts in the property message inbox before FCM delivery.
begin;

alter table public.property_messages
  add column if not exists source text,
  add column if not exists external_message_id text;

create unique index if not exists property_messages_source_external_idx
  on public.property_messages(source,external_message_id)
  where source is not null and external_message_id is not null;

create or replace function public.save_telegram_urgent_message_service(
  p_management_number text,
  p_message text,
  p_external_id text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_property public.properties%rowtype;
  v_owner_id uuid;
  v_message_id uuid;
  v_text text:=btrim(coalesce(p_message,''));
  v_recipient_count integer:=0;
begin
  if char_length(v_text) not between 1 and 2000 then
    return jsonb_build_object('ok',false,'code','invalid_message','message','긴급 메세지 내용을 확인해주세요.');
  end if;
  if btrim(coalesce(p_external_id,''))='' then
    return jsonb_build_object('ok',false,'code','invalid_external_id','message','텔레그램 메세지 번호가 없습니다.');
  end if;

  select p.* into v_property
  from public.properties p
  where p.management_number::text=btrim(coalesce(p_management_number,''))
  limit 1;
  if not found then
    return jsonb_build_object('ok',false,'code','property_not_found','message','숙소번호를 찾지 못했습니다.');
  end if;

  select o.id into v_owner_id
  from public.owners o
  where o.property_id=v_property.id and o.active
  order by o.created_at,o.id
  limit 1;
  if v_owner_id is null then
    return jsonb_build_object('ok',false,'code','owner_not_found','message','활성 사장 계정을 찾지 못했습니다.');
  end if;

  select m.id into v_message_id
  from public.property_messages m
  where m.source='telegram' and m.external_message_id=p_external_id;

  if v_message_id is null then
    insert into public.property_messages(
      business_id,property_id,sender_type,sender_owner_id,message,priority,
      message_type,source,external_message_id
    ) values(
      v_property.business_id,v_property.id,'owner',v_owner_id,v_text,'urgent',
      'general','telegram',p_external_id
    ) returning id into v_message_id;

    insert into public.property_message_recipients(
      message_id,recipient_key,recipient_type,employee_id
    )
    select v_message_id,'employee:'||e.id,'staff',e.id
    from public.employees e
    where e.property_id=v_property.id and e.active and e.role<>'owner'
    on conflict(message_id,recipient_key) do nothing;
  end if;

  select count(*)::integer into v_recipient_count
  from public.property_message_recipients r
  where r.message_id=v_message_id and r.employee_id is not null;

  return jsonb_build_object(
    'ok',true,
    'message_id',v_message_id,
    'recipient_count',v_recipient_count,
    'priority','urgent'
  );
end;
$$;

revoke all on function public.save_telegram_urgent_message_service(text,text,text)
  from public,anon,authenticated;
grant execute on function public.save_telegram_urgent_message_service(text,text,text)
  to service_role;

commit;

select 'telegram urgent inbox persistence installed' as migration_status;
