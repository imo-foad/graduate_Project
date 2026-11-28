-- 0044: secure profile/career ownership semantics without changing Social Feed objects.
--
-- Existing contract:
--   * profiles: owners may edit their own full_name.
--   * avatar_url has no approved upload/storage flow in this version; clients must not inject URLs.
--   * graduate_profiles are provisioned only for verified GRADUATE identities.
--   * career_history is auditable and has no client hard-delete path.
--   * current employment is managed atomically through set_current_job().
--
-- This migration is forward-only. It preserves every existing profile/career row.

-- No avatar upload endpoint/bucket currently exists. Until an approved owner-scoped upload flow is
-- introduced, avatar_url is server-managed and must not accept arbitrary client-supplied URLs.
revoke update (avatar_url) on public.profiles from authenticated;
comment on column public.profiles.avatar_url is
  'Server-managed. Authenticated clients cannot write this field directly; no approved avatar upload flow is currently exposed.';

-- A Student/Faculty identity has a valid basic profile but no graduate career profile. Keep the
-- career-history insert boundary aligned with that identity model and fail closed before the FK.
drop policy if exists ch_insert on public.career_history;
create policy ch_insert on public.career_history
  for insert to authenticated
  with check (
    graduate_id = (select auth.uid())
    and source = 'SELF_REPORTED'
    and exists (
      select 1
        from public.graduate_profiles gp
       where gp.profile_id = (select auth.uid())
    )
  );

-- Stable business error for non-graduate identities. Do not rely on a low-level FK violation when a
-- Student/Faculty account invokes the current-job workflow.
create or replace function public.set_current_job(
  p_company_name text,
  p_job_title text,
  p_start_date date,
  p_field text default null,
  p_description text default null
)
returns public.career_history
language plpgsql
security definer
set search_path = ''
as $set_current_job_profile_guard$
declare
  v_uid uuid := public._require_uid();
  cur public.career_history;
  nw public.career_history;
begin
  if btrim(coalesce(p_company_name, '')) = ''
     or btrim(coalesce(p_job_title, '')) = ''
     or p_start_date is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  -- Only a verified GRADUATE identity receives a graduate_profiles row. Basic profile access for
  -- Student/Faculty accounts remains independent from this graduate-only career operation.
  if not exists (
    select 1
      from public.graduate_profiles gp
     where gp.profile_id = v_uid
  ) then
    raise exception 'GRADUATE_PROFILE_REQUIRED' using errcode = 'PT403';
  end if;

  -- Serialize updates to a person's current-career row.
  perform 1
    from public.graduate_profiles gp
   where gp.profile_id = v_uid
   for update;

  select *
    into cur
    from public.career_history
   where graduate_id = v_uid
     and is_current;

  if found then
    if p_start_date < cur.start_date then
      raise exception 'START_BEFORE_PREVIOUS' using errcode = 'PT422';
    end if;

    update public.career_history
       set end_date = p_start_date,
           is_current = false
     where id = cur.id;
  end if;

  insert into public.career_history (
    graduate_id,
    company_name,
    job_title,
    field,
    description,
    start_date,
    is_current,
    source
  )
  values (
    v_uid,
    btrim(p_company_name),
    btrim(p_job_title),
    p_field,
    p_description,
    p_start_date,
    true,
    'SELF_REPORTED'
  )
  returning * into nw;

  update public.graduate_profiles
     set employment_status = 'EMPLOYED'
   where profile_id = v_uid;

  return nw;
end
$set_current_job_profile_guard$;

comment on function public.set_current_job(text, text, date, text, text) is
  'Atomically closes any current career-history row and inserts the new current job. Requires the caller to own a graduate_profiles row; Student/Faculty-only callers receive GRADUATE_PROFILE_REQUIRED. Career history is preserved and has no client hard-delete path.';
