-- 0002: read-only opportunity catalogue (loaded from seed data; no client writes, BR-004/BR-019).
create table public.opportunities (
  id uuid primary key default gen_random_uuid(),
  seed_key text not null unique,
  type text not null check (type in ('JOB','INTERNSHIP','TRAINING','EVENT','CONFERENCE','COMPETITION','VOLUNTEER','SCHOLARSHIP')),
  title text not null,
  company_name text,
  organizer_name text,
  description text not null default '',
  location text,
  attendance_mode text not null default 'ONSITE' check (attendance_mode in ('ONSITE','ONLINE','HYBRID')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','CLOSED','EXPIRED','CANCELLED')),
  deadline timestamptz,
  start_at timestamptz,
  end_at timestamptz,
  registration_opens_at timestamptz,
  capacity integer check (capacity is null or capacity > 0),
  registered_count integer not null default 0 check (registered_count >= 0),
  waitlist_enabled boolean not null default false,
  target_fields text[] not null default '{}',
  is_sample boolean not null default true,
  seed_version text not null default 'v1',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_at is null or end_at is null or end_at >= start_at),
  check (deadline is null or coalesce(end_at, start_at) is null or deadline <= coalesce(end_at, start_at)),
  check (capacity is null or registered_count <= capacity)
);
create trigger opportunities_updated_at before update on public.opportunities
  for each row execute function public.set_updated_at();
create index opportunities_type_status_deadline_idx on public.opportunities (type, status, deadline);

create table public.job_details (
  opportunity_id uuid primary key references public.opportunities (id) on delete cascade,
  employment_type text check (employment_type in ('FULL_TIME','PART_TIME','CONTRACT','INTERNSHIP')),
  experience_level text check (experience_level in ('FRESH_GRADUATE','JUNIOR','MID','SENIOR')),
  minimum_qualification text,
  salary_range text
);

create table public.event_details (
  opportunity_id uuid primary key references public.opportunities (id) on delete cascade,
  venue text,
  target_audience text,
  registration_required boolean not null default true
);

create table public.opportunity_skills (
  opportunity_id uuid not null references public.opportunities (id) on delete cascade,
  skill_id text not null references public.skills (id),
  importance smallint not null default 3 check (importance between 1 and 5),
  minimum_level smallint not null default 1 check (minimum_level between 1 and 5),
  is_required boolean not null default false,
  primary key (opportunity_id, skill_id)
);
create index opportunity_skills_skill_idx on public.opportunity_skills (skill_id);

-- ASSUMPTION A1: hard eligibility (BR-017) is modelled here, separate from skill weighting,
-- because the source does not define the shape of "mandatory requirements".
create table public.opportunity_eligibility (
  opportunity_id uuid primary key references public.opportunities (id) on delete cascade,
  min_graduation_year integer,
  max_graduation_year integer,
  allowed_degrees text[] not null default '{}',
  required_certifications text[] not null default '{}',
  check (min_graduation_year is null or max_graduation_year is null or min_graduation_year <= max_graduation_year)
);
