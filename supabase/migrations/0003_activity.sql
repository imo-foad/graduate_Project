-- 0003: graduate activity tables. Writes happen only through SECURITY DEFINER RPCs (0004).
create table public.saved_opportunities (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  opportunity_id uuid not null references public.opportunities (id),
  saved_at timestamptz not null default now(),
  unique (graduate_id, opportunity_id)
);

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.opportunities (id),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  cv_document_id uuid references public.cv_documents (id) on delete set null,
  status text not null default 'SUBMITTED' check (status in
    ('SUBMITTED','WITHDRAWN','SAMPLE_UNDER_REVIEW','SAMPLE_INTERVIEW','SAMPLE_ACCEPTED','SAMPLE_REJECTED')),
  status_source text not null default 'APP_ACTION' check (status_source in ('APP_ACTION','SEED_SAMPLE')),
  applied_at timestamptz not null default now(),
  note text,
  unique (graduate_id, opportunity_id), -- BR-007
  check ((status like 'SAMPLE\_%') = (status_source = 'SEED_SAMPLE')) -- BR-011
);
create index applications_graduate_idx on public.applications (graduate_id, applied_at desc);

create table public.application_status_history (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications (id) on delete cascade,
  old_status text,
  new_status text not null,
  source_type text not null check (source_type in ('APP_ACTION','SEED_SAMPLE')),
  changed_at timestamptz not null default now(),
  note text
);
create index application_status_history_app_idx on public.application_status_history (application_id, changed_at);

create table public.event_registrations (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.opportunities (id),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  status text not null check (status in ('REGISTERED','WAITLISTED','CANCELLED')),
  source text not null default 'APP_ACTION' check (source in ('APP_ACTION','SEED_SAMPLE')),
  registered_at timestamptz not null default now(),
  attendance_status text check (attendance_status in ('ATTENDED','NO_SHOW')),
  attendance_source text check (attendance_source in ('SELF_REPORTED','SEED_SAMPLE')),
  unique (graduate_id, opportunity_id) -- BR-012
);
create index event_registrations_graduate_idx on public.event_registrations (graduate_id);

create table public.recommendations (
  id uuid primary key default gen_random_uuid(),
  graduate_id uuid not null references public.graduate_profiles (profile_id) on delete cascade,
  opportunity_id uuid not null references public.opportunities (id) on delete cascade,
  score numeric(5,2) not null check (score between 0 and 100),
  band text not null check (band in ('HIGH','GOOD','MEDIUM','LOW')),
  score_breakdown jsonb not null default '{}'::jsonb,
  reasons jsonb not null default '[]'::jsonb,
  explanation_ar text,
  matched_skill_ids jsonb not null default '[]'::jsonb,
  missing_skill_ids jsonb not null default '[]'::jsonb,
  gaps jsonb not null default '[]'::jsonb,
  model_version text not null, -- BR-022
  generated_at timestamptz not null default now(),
  unique (graduate_id, opportunity_id)
);
create index recommendations_graduate_score_idx on public.recommendations (graduate_id, score desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  title text not null, body text not null,
  type text not null,
  related_entity_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_profile_idx on public.notifications (profile_id, is_read, created_at desc);
