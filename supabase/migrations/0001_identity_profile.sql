-- 0001: identity + graduate profile. One account type only (Graduate).
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null check (length(btrim(full_name)) between 1 and 200),
  email text not null,
  avatar_url text,
  account_status text not null default 'ACTIVE' check (account_status in ('ACTIVE','SUSPENDED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- BR-003: profile_id is both PK and FK => exactly one graduate profile per account.
create table public.graduate_profiles (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  college text, department text, major text,
  graduation_year integer check (graduation_year between 1990 and 2100),
  degree text,
  employment_status text not null default 'NOT_SPECIFIED'
    check (employment_status in ('SEEKING','EMPLOYED','FREELANCER','ENTREPRENEUR','POSTGRADUATE','OTHER','NOT_SPECIFIED')),
  location text,
  career_interests text[] not null default '{}',
  work_preferences jsonb not null default '{}'::jsonb,
  hidden_fields text[] not null default '{}'
    check (hidden_fields <@ array['location','career_interests','work_preferences','avatar_url']),
  recommendations_dirty boolean not null default true,
  profile_updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger graduate_profiles_updated_at before update on public.graduate_profiles
  for each row execute function public.set_updated_at();

create table public.skills (
  id text primary key check (id ~ '^[A-Z0-9_]+$'),
  canonical_name text not null unique,
  category text not null,
  aliases text[] not null default '{}',
  description text
);

create table public.graduate_skills (
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  skill_id text not null references public.skills (id),
  level smallint not null check (level between 1 and 5),
  years_experience numeric(4,1) check (years_experience is null or years_experience >= 0),
  source text not null default 'MANUAL' check (source in ('MANUAL','CV_CONFIRMED','SEED')),
  confirmed_at timestamptz not null default now(),
  primary key (graduate_id, skill_id)
);
create index graduate_skills_skill_idx on public.graduate_skills (skill_id);

create table public.career_history (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  company_name text not null check (length(btrim(company_name)) > 0),
  job_title text not null check (length(btrim(job_title)) > 0),
  field text, description text,
  start_date date not null,
  end_date date,
  is_current boolean not null default false,
  source text not null default 'SELF_REPORTED' check (source in ('SELF_REPORTED','CV_CONFIRMED','SEED_SAMPLE')),
  created_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date),
  check (is_current = (end_date is null))
);
create unique index career_history_one_current on public.career_history (graduate_id) where is_current;
create index career_history_graduate_idx on public.career_history (graduate_id, start_date desc);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  title text not null, description text,
  skills_used text[] not null default '{}', reference_url text,
  created_at timestamptz not null default now()
);
create index projects_graduate_idx on public.projects (graduate_id);

create table public.certifications (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  title text not null, issuer text, issue_date date, reference_url text,
  created_at timestamptz not null default now()
);
create index certifications_graduate_idx on public.certifications (graduate_id);

create table public.cv_documents (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  storage_path text not null unique,
  file_type text not null check (file_type in ('pdf','docx')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  is_active boolean not null default false,
  parse_status text not null default 'PENDING' check (parse_status in ('PENDING','PROCESSING','DONE','FAILED')),
  error_message text,
  uploaded_at timestamptz not null default now(),
  parsed_at timestamptz
);
create unique index cv_documents_one_active on public.cv_documents (graduate_id) where is_active;

-- BR-015: extracted items stay PENDING until the graduate confirms. v1 supports SKILL only.
create table public.cv_suggestions (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  cv_document_id uuid not null references public.cv_documents (id) on delete cascade,
  kind text not null check (kind in ('SKILL')),
  payload jsonb not null,
  status text not null default 'PENDING' check (status in ('PENDING','CONFIRMED','REJECTED')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index cv_suggestions_graduate_idx on public.cv_suggestions (graduate_id, status);

-- Provision profile rows when an Auth user is created (demo accounts are created by an admin script).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
          new.email);
  insert into public.graduate_profiles (profile_id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Mark cached recommendations stale only when inputs that affect matching change.
create or replace function public.mark_recommendations_dirty() returns trigger
language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if tg_op = 'DELETE' then gid := old.graduate_id; else gid := new.graduate_id; end if;
  update public.graduate_profiles set recommendations_dirty = true, profile_updated_at = now()
   where profile_id = gid;
  return null;
end $$;
create trigger graduate_skills_dirty after insert or update or delete on public.graduate_skills
  for each row execute function public.mark_recommendations_dirty();
create trigger certifications_dirty after insert or update or delete on public.certifications
  for each row execute function public.mark_recommendations_dirty();
create trigger career_history_dirty after insert or update or delete on public.career_history
  for each row execute function public.mark_recommendations_dirty();

create or replace function public.graduate_profile_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.profile_updated_at := now();
  if (new.college, new.department, new.major, new.graduation_year, new.degree, new.location,
      new.career_interests, new.work_preferences)
     is distinct from
     (old.college, old.department, old.major, old.graduation_year, old.degree, old.location,
      old.career_interests, old.work_preferences)
  then new.recommendations_dirty := true; end if;
  return new;
end $$;
create trigger graduate_profiles_touch before update on public.graduate_profiles
  for each row execute function public.graduate_profile_touch();
