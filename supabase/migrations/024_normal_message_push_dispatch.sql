-- Allow the authenticated message sender to dispatch both normal and urgent push notifications.
begin;

create or replace function public.get_message_push_dispatch(p_access_token uuid,p_message_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner_id uuid;
  v_employee_id uuid;
  v_property_id uuid;
  v_message public.property_messages%rowtype;
  v_number integer;
begin
  select s.owner_id,s.property_id into v_owner_id,v_property_id
  from public.owner_sessions s
  join public.owners o on o.id=s.owner_id
  where s.login_token_hash=omg_private.token_hash(p_access_token)
    and s.token_expires_at>clock_timestamp() and o.active;

  if not found then
    select s.employee_id,s.property_id into v_employee_id,v_property_id
    from public.work_sessions s
    join public.employees e on e.id=s.employee_id
    where s.login_token_hash=omg_private.token_hash(p_access_token)
      and s.token_expires_at>clock_timestamp() and e.active
      and s.status in('working','completed');
    if not found then
      return jsonb_build_object('ok',false,'code','invalid_session','message','로그인이 만료되었습니다.');
    end if;
  end if;

  select * into v_message
  from public.property_messages
  where id=p_message_id and property_id=v_property_id
    and((v_owner_id is not null and sender_owner_id=v_owner_id)
      or(v_employee_id is not null and sender_employee_id=v_employee_id));
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','message','전송할 메세지를 찾을 수 없습니다.');
  end if;

  select management_number into v_number from public.properties where id=v_property_id;
  return jsonb_build_object(
    'ok',true,
    'management_number',v_number,
    'message_id',v_message.id,
    'message',v_message.message,
    'priority',v_message.priority,
    'message_type',v_message.message_type,
    'sender_label',case when v_message.sender_type='owner' then '사장님'
      else coalesce((select display_name from public.employees where id=v_message.sender_employee_id),'직원') end,
    'recipient_employee_ids',coalesce((select jsonb_agg(employee_id) from public.property_message_recipients where message_id=v_message.id and employee_id is not null),'[]'::jsonb),
    'recipient_owner_ids',coalesce((select jsonb_agg(owner_id) from public.property_message_recipients where message_id=v_message.id and owner_id is not null),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_message_push_dispatch(uuid,uuid) from public;
grant execute on function public.get_message_push_dispatch(uuid,uuid) to anon,authenticated;

commit;
