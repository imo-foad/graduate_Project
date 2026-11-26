-- 0034: typed synthetic university academic records (forward-only).
-- Synthetic records support local development and integration tests only; they are not institutional claims.

alter table public.human_identities
  drop constraint if exists human_identities_verification_source_check;
alter table public.human_identities
  add constraint human_identities_verification_source_check
  check (verification_source in (
    'INSTITUTION_PROVIDER','MANUAL_ADMIN','LEGACY_INVITATION','SYNTHETIC_SEED'
  ));

create table public.student_academic_records (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  institution_ref text not null unique check (institution_ref ~ '^SYNTH-STU-[0-9]{4}$'),
  department text not null check (length(btrim(department)) between 1 and 120),
  major text not null check (length(btrim(major)) between 1 and 120),
  academic_track text not null check (academic_track in (
    'Software Engineering','Artificial Intelligence','Data Science and Analytics',
    'Cybersecurity','Mobile Development','Networks and Cloud','Information Systems'
  )),
  academic_level smallint not null check (academic_level between 1 and 5),
  gpa numeric(3,2) not null check (gpa between 0.00 and 4.00),
  gpa_scale numeric(2,1) not null default 4.0 check (gpa_scale = 4.0),
  record_source text not null default 'SYNTHETIC_SEED'
    check (record_source in ('SYNTHETIC_SEED','INSTITUTION_PROVIDER','MANUAL_ADMIN')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index student_academic_records_track_idx on public.student_academic_records(academic_track);
create index student_academic_records_department_idx on public.student_academic_records(department);

create table public.faculty_academic_records (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  institution_ref text not null unique check (institution_ref ~ '^SYNTH-FAC-[0-9]{4}$'),
  department text not null check (length(btrim(department)) between 1 and 120),
  specialization text not null check (length(btrim(specialization)) between 1 and 160),
  academic_title text not null check (academic_title in (
    'PROFESSOR','ASSOCIATE_PROFESSOR','ASSISTANT_PROFESSOR',
    'LECTURER','ASSISTANT_LECTURER','TEACHING_ASSISTANT'
  )),
  record_source text not null default 'SYNTHETIC_SEED'
    check (record_source in ('SYNTHETIC_SEED','INSTITUTION_PROVIDER','MANUAL_ADMIN')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index faculty_academic_records_department_idx on public.faculty_academic_records(department);

create or replace function private.require_verified_academic_record_identity()
returns trigger language plpgsql security definer set search_path = ''
as $require_verified_academic_record_identity$
declare v_identity_type text;
begin
  v_identity_type := case tg_table_name
    when 'student_academic_records' then 'STUDENT'
    when 'faculty_academic_records' then 'FACULTY'
    else null
  end;
  if v_identity_type is null or not exists (
    select 1 from public.human_identities h
     where h.profile_id = new.profile_id
       and h.identity_type = v_identity_type
       and h.status = 'VERIFIED'
  ) then
    raise exception 'VERIFIED_ACADEMIC_IDENTITY_REQUIRED' using errcode = '23514';
  end if;
  return new;
end
$require_verified_academic_record_identity$;
revoke all on function private.require_verified_academic_record_identity() from public, anon, authenticated;

create trigger student_academic_identity_guard
  before insert or update on public.student_academic_records
  for each row execute function private.require_verified_academic_record_identity();
create trigger faculty_academic_identity_guard
  before insert or update on public.faculty_academic_records
  for each row execute function private.require_verified_academic_record_identity();

alter table public.student_academic_records enable row level security;
alter table public.faculty_academic_records enable row level security;
revoke all on public.student_academic_records, public.faculty_academic_records from public, anon, authenticated;
grant select, insert, update, delete on public.student_academic_records, public.faculty_academic_records to service_role;
grant select on public.student_academic_records, public.faculty_academic_records to authenticated;
create policy student_academic_records_select_own on public.student_academic_records
  for select to authenticated using (profile_id = (select auth.uid()));
create policy faculty_academic_records_select_own on public.faculty_academic_records
  for select to authenticated using (profile_id = (select auth.uid()));

create trigger student_academic_records_updated_at
  before update on public.student_academic_records for each row execute function public.set_updated_at();
create trigger faculty_academic_records_updated_at
  before update on public.faculty_academic_records for each row execute function public.set_updated_at();

comment on table public.student_academic_records is
  'Typed academic attributes for STUDENT identities. Service role only; synthetic demo rows are simulated local data, not institutional claims.';
comment on table public.faculty_academic_records is
  'Typed department, specialization and academic title for FACULTY identities. Service role only; synthetic rows are simulated local data.';
comment on column public.student_academic_records.gpa_scale is
  'Synthetic demo convention fixed at 4.0; it is not a statement of the university grading policy.';
