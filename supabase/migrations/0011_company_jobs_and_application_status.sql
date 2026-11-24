-- 0011: verified company accounts, employer-managed job postings and application status updates.
-- Existing graduate access remains unchanged. Company powers are granted only through company memberships.
-- Platform-admin membership is provisioned out-of-band by service_role; never trust user-editable metadata.

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 200),
  website text,
  description text,
  verification_status text not null default 'PENDING_REVIEW'
    check (verification_status in ('PENDING_REVIEW','VERIFIED','REJECTED','SUSPENDED')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger companies_updated_at before update on public.companies
  for each row execute function public.set_updated_at();

create table public.company_memberships (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('OWNER','RECRUITER','VIEWER')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);
create index company_memberships_user_idx on public.company_memberships(user_id, is_active);

create table public.company_verification_history (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  old_status text not null,
  new_status text not null,
  note text,
  changed_at timestamptz not null default now()
);
create index company_verification_history_company_idx
  on public.company_verification_history(company_id, changed_at desc);

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create table private.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table private.platform_admins enable row level security;
revoke all on private.platform_admins from public, anon, authenticated;
grant select, insert, update, delete on private.platform_admins to service_role;

create or replace function private.is_platform_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from private.platform_admins a
    where a.user_id = auth.uid() and a.is_active
  );
$$;

create or replace function private.is_company_member(
  p_company_id uuid,
  p_roles text[] default array['OWNER','RECRUITER','VIEWER']::text[]
)
returns boolean
language sql stable security definer set search_path = ''
as $company_member_guard$
  select auth.uid() is not null and exists (
    select 1 from public.company_memberships m
    where m.company_id = p_company_id and m.user_id = auth.uid()
      and m.is_active and m.role = any(p_roles)
  );
$company_member_guard$;



alter table public.opportunities
  add column company_id uuid references public.companies(id) on delete restrict,
  add column created_by uuid references auth.users(id) on delete set null,
  add column published_at timestamptz;

-- Break the applications <-> opportunities policy cycle. The SECURITY DEFINER
-- function reads the relationship without recursively invoking either table's RLS.
create or replace function private.can_view_company_application(p_application_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $company_application_guard$
  select auth.uid() is not null and (
    private.is_platform_admin()
    or exists (
      select 1
      from public.applications a
      join public.opportunities o on o.id = a.opportunity_id
      join public.company_memberships m on m.company_id = o.company_id
      where a.id = p_application_id
        and m.user_id = auth.uid()
        and m.is_active
        and m.role in ('OWNER','RECRUITER','VIEWER')
    )
  );
$company_application_guard$;

revoke all on function private.is_platform_admin() from public, anon, authenticated;
revoke all on function private.is_company_member(uuid, text[]) from public, anon, authenticated;
revoke all on function private.can_view_company_application(uuid) from public, anon, authenticated;
grant execute on function private.is_platform_admin() to authenticated;
grant execute on function private.is_company_member(uuid, text[]) to authenticated;
grant execute on function private.can_view_company_application(uuid) to authenticated;

alter table public.opportunities drop constraint if exists opportunities_status_check;
alter table public.opportunities add constraint opportunities_status_check
  check (status in ('DRAFT','ACTIVE','CLOSED','EXPIRED','CANCELLED'));

alter table public.applications drop constraint if exists applications_status_check;
alter table public.applications add constraint applications_status_check
  check (status in ('SUBMITTED','UNDER_REVIEW','SHORTLISTED','INTERVIEW','ACCEPTED','REJECTED','WITHDRAWN',
                    'SAMPLE_UNDER_REVIEW','SAMPLE_INTERVIEW','SAMPLE_ACCEPTED','SAMPLE_REJECTED'));
alter table public.applications drop constraint if exists applications_status_source_check;
alter table public.applications add constraint applications_status_source_check
  check (status_source in ('APP_ACTION','COMPANY_ACTION','ADMIN_ACTION','SEED_SAMPLE'));

alter table public.application_status_history
  add column actor_user_id uuid references auth.users(id) on delete set null;
alter table public.application_status_history drop constraint if exists application_status_history_source_type_check;
alter table public.application_status_history add constraint application_status_history_source_type_check
  check (source_type in ('APP_ACTION','COMPANY_ACTION','ADMIN_ACTION','SEED_SAMPLE'));

-- Functions below are the only client write path for company-managed data.
create or replace function public.create_company(
  p_name text, p_website text default null, p_description text default null
)
returns public.companies
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := public._require_uid(); c public.companies;
begin
  if length(btrim(coalesce(p_name,''))) < 2 or length(btrim(p_name)) > 200 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.companies(name, website, description, created_by)
  values (btrim(p_name), nullif(btrim(coalesce(p_website,'')), ''),
          nullif(btrim(coalesce(p_description,'')), ''), v_uid)
  returning * into c;
  insert into public.company_memberships(company_id, user_id, role)
  values (c.id, v_uid, 'OWNER');
  return c;
end $$;

create or replace function public.create_company_job(
  p_company_id uuid,
  p_title text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null,
  p_employment_type text default 'FULL_TIME',
  p_experience_level text default 'FRESH_GRADUATE'
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := public._require_uid(); c public.companies; o public.opportunities;
begin
  if not private.is_company_member(p_company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  select * into c from public.companies where id = p_company_id for share;
  if not found then raise exception 'COMPANY_NOT_FOUND' using errcode = 'PT404'; end if;
  if length(btrim(coalesce(p_title,''))) < 3 or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or p_employment_type is null or p_employment_type not in ('FULL_TIME','PART_TIME','CONTRACT','INTERNSHIP')
     or p_experience_level is null or p_experience_level not in ('FRESH_GRADUATE','JUNIOR','MID','SENIOR')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.opportunities(
    seed_key, type, title, company_name, description, location, attendance_mode,
    status, deadline, is_sample, company_id, created_by
  ) values (
    'company-' || gen_random_uuid()::text, 'JOB', btrim(p_title), c.name, p_description,
    nullif(btrim(coalesce(p_location,'')), ''), p_attendance_mode,
    'DRAFT', p_deadline, false, p_company_id, v_uid
  ) returning * into o;
  insert into public.job_details(opportunity_id, employment_type, experience_level)
  values (o.id, p_employment_type, p_experience_level);
  return o;
end $$;

create or replace function public.update_company_job(
  p_opportunity_id uuid,
  p_title text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := public._require_uid(); o public.opportunities;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.company_id is null then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_EDITABLE' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_title,''))) < 3 or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.opportunities set title = btrim(p_title), description = p_description,
    location = nullif(btrim(coalesce(p_location,'')), ''), attendance_mode = p_attendance_mode,
    deadline = p_deadline
  where id = o.id returning * into o;
  return o;
end $$;

create or replace function public.publish_company_job(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $$
declare o public.opportunities; v_status text;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.company_id is null then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  select verification_status into v_status from public.companies where id = o.company_id;
  if v_status <> 'VERIFIED' then
    raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
  end if;
  if o.status <> 'DRAFT' then raise exception 'OPPORTUNITY_NOT_DRAFT' using errcode = 'PT422'; end if;
  if o.deadline is not null and o.deadline <= now() then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'ACTIVE', published_at = now()
   where id = o.id returning * into o;
  return o;
end $$;

create or replace function public.close_company_job(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $$
declare o public.opportunities;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.company_id is null then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_OPEN' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'CLOSED' where id = o.id returning * into o;
  return o;
end $$;

create or replace function public.review_company(
  p_company_id uuid, p_decision text, p_note text default null
)
returns public.companies
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := public._require_uid(); c public.companies; v_old text;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_decision is null or p_decision not in ('VERIFIED','REJECTED','SUSPENDED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into c from public.companies where id = p_company_id for update;
  if not found then raise exception 'COMPANY_NOT_FOUND' using errcode = 'PT404'; end if;
  v_old := c.verification_status;
  update public.companies set verification_status = p_decision where id = c.id returning * into c;
  insert into public.company_verification_history(company_id, actor_user_id, old_status, new_status, note)
  values (c.id, v_uid, v_old, p_decision, nullif(btrim(coalesce(p_note,'')), ''));
  return c;
end $$;

create or replace function public.update_application_status(
  p_application_id uuid, p_status text, p_note text default null
)
returns public.applications
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := public._require_uid();
  a public.applications;
  o public.opportunities;
  v_old_status text;
begin
  if p_status is null or p_status not in ('UNDER_REVIEW','SHORTLISTED','INTERVIEW','ACCEPTED','REJECTED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into a from public.applications where id = p_application_id for update;
  if not found then raise exception 'APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into o from public.opportunities where id = a.opportunity_id;
  if o.company_id is null or not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if a.status_source = 'SEED_SAMPLE' or a.status = 'WITHDRAWN'
     or a.status in ('ACCEPTED','REJECTED') then
    raise exception 'APPLICATION_NOT_UPDATABLE' using errcode = 'PT422';
  end if;
  v_old_status := a.status;
  update public.applications set status = p_status, status_source = 'COMPANY_ACTION'
   where id = a.id returning * into a;
  insert into public.application_status_history(application_id, old_status, new_status, source_type, actor_user_id, note)
  values (a.id, v_old_status, p_status, 'COMPANY_ACTION', v_uid, nullif(btrim(coalesce(p_note,'')), ''));
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (a.graduate_id, 'تحديث حالة طلب التوظيف',
          'تم تحديث حالة طلبك على «' || o.title || '» إلى: ' || p_status || '.',
          'APPLICATION_STATUS_UPDATED', a.id);
  return a;
end $$;

-- Company-facing reads; company users never gain cross-company or cross-graduate access.
alter table public.companies enable row level security;
alter table public.company_memberships enable row level security;
alter table public.company_verification_history enable row level security;

create policy companies_select_members on public.companies for select to authenticated
  using (private.is_company_member(id) or private.is_platform_admin());
create policy company_memberships_select_members on public.company_memberships for select to authenticated
  using (user_id = (select auth.uid()) or private.is_company_member(company_id) or private.is_platform_admin());
create policy company_verification_history_select_members on public.company_verification_history for select to authenticated
  using (private.is_company_member(company_id) or private.is_platform_admin());

create policy company_opportunities_select on public.opportunities for select to authenticated
  using (company_id is not null and private.is_company_member(company_id));
create policy company_applications_select on public.applications for select to authenticated
  using (private.can_view_company_application(id));
create policy company_application_history_select on public.application_status_history for select to authenticated
  using (private.can_view_company_application(application_id));

grant select on public.companies, public.company_memberships, public.company_verification_history to authenticated;

revoke all on function public.create_company(text, text, text) from public, anon, authenticated;
revoke all on function public.create_company_job(uuid, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.update_company_job(uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.publish_company_job(uuid) from public, anon, authenticated;
revoke all on function public.close_company_job(uuid) from public, anon, authenticated;
revoke all on function public.review_company(uuid, text, text) from public, anon, authenticated;
revoke all on function public.update_application_status(uuid, text, text) from public, anon, authenticated;

grant execute on function public.create_company(text, text, text),
  public.create_company_job(uuid, text, text, text, text, timestamptz, text, text),
  public.update_company_job(uuid, text, text, text, text, timestamptz),
  public.publish_company_job(uuid), public.close_company_job(uuid),
  public.review_company(uuid, text, text), public.update_application_status(uuid, text, text)
to authenticated;

comment on table public.companies is 'Company accounts; publishing is gated by admin verification.';
comment on table public.company_memberships is 'Company-scoped roles. Membership is the authorization source, not user metadata.';
comment on table public.company_verification_history is 'Append-only audit trail of platform-admin company verification decisions.';
comment on column public.opportunities.company_id is 'Non-null for company-owned posts; seeded opportunities remain null.';
comment on column public.application_status_history.actor_user_id is 'Authenticated user who changed the status; null for older/system-seeded history.';

-- Company-managed applications are real; retain the explicit demo disclaimer only for seeded catalogue rows.
create or replace function public.apply_for_job(
  p_opportunity_id uuid, p_cv_document_id uuid default null, p_note text default null)
returns public.applications language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities; f text[]; app public.applications;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'JOB' then raise exception 'NOT_A_JOB' using errcode = 'PT422'; end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  if p_cv_document_id is not null and not exists (
       select 1 from public.cv_documents where id = p_cv_document_id and graduate_id = v_uid) then
    raise exception 'CV_NOT_FOUND' using errcode = 'PT404';
  end if;
  begin
    insert into public.applications (opportunity_id, graduate_id, cv_document_id, note)
    values (o.id, v_uid, p_cv_document_id, p_note) returning * into app;
  exception when unique_violation then
    raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;
  insert into public.application_status_history (application_id, old_status, new_status, source_type, actor_user_id)
  values (app.id, null, 'SUBMITTED', 'APP_ACTION', v_uid);
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم تقديم طلبك',
          case when o.company_id is not null
               then 'تم إرسال طلبك إلى ' || coalesce(o.company_name, 'الشركة') || ' على «' || o.title || '».'
               else 'تم إنشاء طلب التقديم على «' || o.title || '» (بيانات تجريبية، لا يوجد قرار توظيف حقيقي).'
          end,
          'APPLICATION_SUBMITTED', app.id);
  return app;
end $$;

