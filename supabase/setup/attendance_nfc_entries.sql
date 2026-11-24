-- Keep arrival choices private; all reads/writes require a valid work-session RPC.
create table if not exists omg_private.attendance_nfc_entries (
 id uuid primary key default gen_random_uuid(),
 work_session_id uuid not null references public.work_sessions(id) on delete cascade,
 recorded_at timestamptz not null default clock_timestamp(),
 tag_uid text not null,
 selected boolean not null default false
);
create index if not exists attendance_nfc_entries_session_idx on omg_private.attendance_nfc_entries(work_session_id,recorded_at);
create unique index if not exists attendance_nfc_selected_session_idx on omg_private.attendance_nfc_entries(work_session_id) where selected;
alter table omg_private.attendance_nfc_entries enable row level security;
revoke all on omg_private.attendance_nfc_entries from public,anon,authenticated;
insert into omg_private.attendance_nfc_entries(work_session_id,recorded_at,tag_uid)
 select s.id,s.nfc_entry_at,coalesce(s.nfc_tag_uid,'') from public.work_sessions s
 where s.nfc_entry_at is not null and s.checkin_report_at is null and s.status='working'
 and not exists(select 1 from omg_private.attendance_nfc_entries n where n.work_session_id=s.id);

CREATE OR REPLACE FUNCTION public.attendance_nfc_entry(p_access_token uuid, p_tag_uid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
declare s public.work_sessions%rowtype;basis text;offset_minutes int;tags text[];uid text;seen boolean;stamp timestamptz;entries jsonb;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id
 where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp()
 and e.active and w.status in('working','completed') for update of w;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','근무자 로그인이 만료되었습니다.');end if;
 select clock_in_basis,clock_in_report_offset_minutes,attendance_nfc_tags into basis,offset_minutes,tags from public.properties where id=s.property_id;
 seen:=s.nfc_entry_at is not null;
 if p_tag_uid is not null then
  if basis<>'nfc' then return jsonb_build_object('ok',false,'message','이 지점은 NFC 출근을 사용하지 않습니다.');end if;
  if s.status<>'working' or s.clock_out_at is not null then return jsonb_build_object('ok',false,'message','종료된 근무입니다. 다시 로그인해주세요.');end if;
  uid:=omg_private.normalize_attendance_uid(p_tag_uid);
  if uid is null or not coalesce(uid=any(tags),false) then return jsonb_build_object('ok',false,'code','wrong_tag','message','이 지점에 등록된 NFC 태그가 아닙니다.');end if;
  if s.checkin_report_at is not null then return jsonb_build_object('ok',false,'message','이미 출근보고한 근무입니다. 다음 근무부터 적용됩니다.');end if;
  stamp:=clock_timestamp();
  -- Reader-mode callbacks can repeat while the phone still touches the tag.
  if not exists(select 1 from omg_private.attendance_nfc_entries where work_session_id=s.id and tag_uid=uid and recorded_at>stamp-interval '3 seconds') then
   insert into omg_private.attendance_nfc_entries(work_session_id,recorded_at,tag_uid) values(s.id,stamp,uid);
  end if;
  if not seen then update public.work_sessions set nfc_entry_at=stamp,nfc_tag_uid=uid where id=s.id returning * into s;end if;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'recorded_at',recorded_at) order by recorded_at,id),'[]'::jsonb)
 into entries from omg_private.attendance_nfc_entries where work_session_id=s.id;
 return jsonb_build_object('ok',true,'basis',basis,'report_offset_minutes',offset_minutes,'entry_at',coalesce((select recorded_at from omg_private.attendance_nfc_entries where work_session_id=s.id and selected),s.nfc_entry_at),
 'selected_entry_id',(select id from omg_private.attendance_nfc_entries where work_session_id=s.id and selected),
 'nfc_entries',entries,'already_recorded',seen,'checkin_report_at',s.checkin_report_at,'status',s.status,
 'clock_in_at',s.clock_in_at,'clock_out_at',s.clock_out_at,'unconfirmed_ended_at',s.unconfirmed_ended_at);
end$$;
revoke all on function public.attendance_nfc_entry(uuid,text) from public;
grant execute on function public.attendance_nfc_entry(uuid,text) to anon,authenticated;

-- Choose an arrival when entering the report, without marking the shift checked in.
create or replace function public.attendance_nfc_select(p_access_token uuid,p_entry_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.work_sessions%rowtype;
begin
 select w.* into s from public.work_sessions w join public.employees e on e.id=w.employee_id
 where w.login_token_hash=omg_private.token_hash(p_access_token) and w.token_expires_at>clock_timestamp() and e.active for update of w;
 if not found then return jsonb_build_object('ok',false,'code','invalid_session','message','근무자 로그인이 만료되었습니다.');end if;
 if s.status<>'working' or s.clock_out_at is not null or s.checkin_report_at is not null then return jsonb_build_object('ok',false,'code','session_completed','message','이미 출근보고했거나 종료된 근무입니다.');end if;
 if not exists(select 1 from public.properties where id=s.property_id and clock_in_basis='nfc') then return jsonb_build_object('ok',false,'message','이 지점은 NFC 출근을 사용하지 않습니다.');end if;
 if not exists(select 1 from omg_private.attendance_nfc_entries where id=p_entry_id and work_session_id=s.id and recorded_at<=clock_timestamp()) then return jsonb_build_object('ok',false,'code','invalid_nfc_entry','message','이 근무의 NFC 기록을 선택해주세요.');end if;
 update omg_private.attendance_nfc_entries set selected=false where work_session_id=s.id and selected;
 update omg_private.attendance_nfc_entries set selected=true where id=p_entry_id and work_session_id=s.id;
 return public.attendance_nfc_entry(p_access_token,null);
end$$;
revoke all on function public.attendance_nfc_select(uuid,uuid) from public;
grant execute on function public.attendance_nfc_select(uuid,uuid) to anon,authenticated;
