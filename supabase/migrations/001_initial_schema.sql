-- OMG Works: STEP 1 / TABLES ONLY.
-- Run in the new omg-works-app project as the SQL Editor database owner.
-- This does not deploy the app, create login endpoints, or migrate old reports.
-- Client access stays closed until the authentication stage is reviewed.
begin;

create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  name text not null,
  code text not null,
  timezone text not null default 'Asia/Seoul',
  created_at timestamptz not null default now(),
  unique (business_id, code),
  unique (business_id, id)
);

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  property_id uuid not null,
  display_name text not null,
  pin_hash text,
  role text not null default 'staff' check (role in ('owner','manager','staff')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  foreign key (business_id, property_id)
    references public.properties(business_id, id),
  unique (business_id, property_id, id)
);

create table if not exists public.work_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  property_id uuid not null,
  employee_id uuid not null,
  shift text not null check (shift in ('morning','afternoon')),
  work_date date not null default (now() at time zone 'Asia/Seoul')::date,
  clock_in_at timestamptz not null default now(),
  clock_out_at timestamptz,
  login_token_hash text not null,
  checkin_report_at timestamptz,
  checkout_report_at timestamptz,
  status text not null default 'working' check (status in ('working','completed','needs_review')),
  created_at timestamptz not null default now(),
  foreign key (business_id, property_id, employee_id)
    references public.employees(business_id, property_id, id),
  unique (id, business_id, property_id, employee_id),
  check (clock_out_at is null or clock_out_at >= clock_in_at)
);

create unique index if not exists one_open_work_session_per_employee
  on public.work_sessions(employee_id)
  where clock_out_at is null;

create table if not exists public.work_reports (
  id uuid primary key default gen_random_uuid(),
  work_session_id uuid not null,
  business_id uuid not null,
  property_id uuid not null,
  employee_id uuid not null,
  report_type text not null check (report_type in ('clock_in','clock_out')),
  payload jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now(),
  foreign key (work_session_id, business_id, property_id, employee_id)
    references public.work_sessions(id, business_id, property_id, employee_id),
  check (jsonb_typeof(payload) = 'object')
);

alter table public.businesses enable row level security;
alter table public.properties enable row level security;
alter table public.employees enable row level security;
alter table public.work_sessions enable row level security;
alter table public.work_reports enable row level security;

-- No browser role can directly read or change these tables at this stage.
revoke all on table
  public.businesses, public.properties, public.employees,
  public.work_sessions, public.work_reports
from public, anon, authenticated;

-- Seed records without changing any existing names, PINs, or reports.
insert into public.businesses (name, code)
values ('OMG Works', 'omg')
on conflict (code) do nothing;

insert into public.properties (business_id, name, code)
select id, 'One Minute', 'seoul-station'
from public.businesses where code = 'omg'
on conflict (business_id, code) do nothing;

insert into public.employees (business_id, property_id, display_name)
select b.id, p.id, staff.display_name
from public.businesses b
join public.properties p on p.business_id = b.id
cross join unnest(array['변지훈','문정국','신옥재','정준하']) as staff(display_name)
where b.code = 'omg' and p.code = 'seoul-station'
  and not exists (
    select 1 from public.employees existing
    where existing.property_id = p.id and existing.display_name = staff.display_name
  );

commit;

select 'OMG Works 기본 테이블 준비 완료' as result;
