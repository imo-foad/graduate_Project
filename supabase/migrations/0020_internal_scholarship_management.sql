-- 0020: internal Scholarship organizer controls and central review lifecycle.
-- Scholarships are owned and administered by Alumni Connect; no external provider API exists.

alter table public.scholarship_applications
  drop constraint if exists scholarship_applications_status_check;
alter table public.scholarship_applications
  add constraint scholarship_applications_status_check
  check (status in ('SUBMITTED','UNDER_REVIEW','ACCEPTED','REJECTED','WITHDRAWN'));

alter table public.scholarship_application_status_history
  drop constraint if exists scholarship_application_status_history_new_status_check;
alter table public.scholarship_application_status_history
  add constraint scholarship_application_status_history_new_status_check
  check (new_status in ('SUBMITTED','UNDER_REVIEW','ACCEPTED','REJECTED','WITHDRAWN'));
alter table public.scholarship_application_status_history
  drop constraint if exists scholarship_application_status_history_source_type_check;
alter table public.scholarship_application_status_history
  add constraint scholarship_application_status_history_source_type_check
  check (source_type in ('GRADUATE_ACTION','ADMIN_ACTION'));

create index if not exists scholarship_applications_review_queue_idx
  on public.scholarship_applications(status, applied_at desc, id desc);

-- SECURITY DEFINER helper checks the association without being filtered by applicant-owned RLS.
-- It grants no access to CVs unless they are attached to a Scholarship application.
create or replace function private.can_admin_read_scholarship_cv(p_storage_path text)
returns boolean
language sql stable security definer set search_path = ''
as $can_admin_read_scholarship_cv$
  select auth.uid() is not null
     and private.is_platform_admin()
     and p_storage_path is not null
     and exists (
       select 1
         from public.cv_documents d
         join public.scholarship_applications a on a.cv_document_id = d.id
         join public.opportunities o on o.id = a.opportunity_id
        where d.storage_path = p_storage_path
          and o.type = 'SCHOLARSHIP'
     );
$can_admin_read_scholarship_cv$;
revoke all on function private.can_admin_read_scholarship_cv(text) from public, anon, authenticated;
grant execute on function private.can_admin_read_scholarship_cv(text) to authenticated;

drop policy if exists cv_scholarship_admin_select on public.cv_documents;
create policy cv_scholarship_admin_select on public.cv_documents
  for select to authenticated
  using (private.can_admin_read_scholarship_cv(storage_path));

-- Central admins can download only CV objects attached to Scholarship applications.
drop policy if exists cv_objects_scholarship_admin_select on storage.objects;
create policy cv_objects_scholarship_admin_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'cv-documents'
    and private.can_admin_read_scholarship_cv(name)
  );

create or replace function public.create_admin_scholarship(
  p_title text,
  p_organizer_name text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONLINE',
  p_deadline timestamptz default null,
  p_target_fields text[] default '{}'::text[],
  p_min_graduation_year integer default null,
  p_max_graduation_year integer default null,
  p_allowed_degrees text[] default '{}'::text[],
  p_required_certifications text[] default '{}'::text[]
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $create_admin_scholarship$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if length(btrim(coalesce(p_title,''))) not between 3 and 200
     or length(btrim(coalesce(p_organizer_name,''))) not between 2 and 200
     or length(btrim(coalesce(p_description,''))) not between 10 and 10000
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or (p_deadline is not null and p_deadline <= now())
     or p_target_fields is null or p_allowed_degrees is null or p_required_certifications is null
     or (p_min_graduation_year is not null and p_min_graduation_year not between 1900 and 2200)
     or (p_max_graduation_year is not null and p_max_graduation_year not between 1900 and 2200)
     or (p_min_graduation_year is not null and p_max_graduation_year is not null
         and p_min_graduation_year > p_max_graduation_year) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  insert into public.opportunities(
    seed_key, type, title, organizer_name, description, location, attendance_mode,
    status, deadline, target_fields, is_sample, created_by
  ) values (
    'admin-scholarship-' || gen_random_uuid()::text,
    'SCHOLARSHIP', btrim(p_title), btrim(p_organizer_name), btrim(p_description),
    nullif(btrim(coalesce(p_location,'')), ''), p_attendance_mode,
    'DRAFT', p_deadline, p_target_fields, false, v_uid
  ) returning * into o;

  if p_min_graduation_year is not null or p_max_graduation_year is not null
     or cardinality(p_allowed_degrees) > 0 or cardinality(p_required_certifications) > 0 then
    insert into public.opportunity_eligibility(
      opportunity_id, min_graduation_year, max_graduation_year,
      allowed_degrees, required_certifications
    ) values (
      o.id, p_min_graduation_year, p_max_graduation_year,
      p_allowed_degrees, p_required_certifications
    );
  end if;
  return o;
end
$create_admin_scholarship$;

create or replace function public.update_admin_scholarship(
  p_opportunity_id uuid,
  p_title text,
  p_organizer_name text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONLINE',
  p_deadline timestamptz default null,
  p_target_fields text[] default '{}'::text[],
  p_min_graduation_year integer default null,
  p_max_graduation_year integer default null,
  p_allowed_degrees text[] default '{}'::text[],
  p_required_certifications text[] default '{}'::text[]
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $update_admin_scholarship$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_opportunity_id is null
     or length(btrim(coalesce(p_title,''))) not between 3 and 200
     or length(btrim(coalesce(p_organizer_name,''))) not between 2 and 200
     or length(btrim(coalesce(p_description,''))) not between 10 and 10000
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or (p_deadline is not null and p_deadline <= now())
     or p_target_fields is null or p_allowed_degrees is null or p_required_certifications is null
     or (p_min_graduation_year is not null and p_min_graduation_year not between 1900 and 2200)
     or (p_max_graduation_year is not null and p_max_graduation_year not between 1900 and 2200)
     or (p_min_graduation_year is not null and p_max_graduation_year is not null
         and p_min_graduation_year > p_max_graduation_year) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into o from public.opportunities
   where id = p_opportunity_id and type = 'SCHOLARSHIP'
   for update;
  if not found then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if o.status <> 'DRAFT' then
    raise exception 'OPPORTUNITY_NOT_EDITABLE' using errcode = 'PT422';
  end if;

  update public.opportunities
     set title = btrim(p_title),
         organizer_name = btrim(p_organizer_name),
         description = btrim(p_description),
         location = nullif(btrim(coalesce(p_location,'')), ''),
         attendance_mode = p_attendance_mode,
         deadline = p_deadline,
         target_fields = p_target_fields
   where id = o.id
   returning * into o;

  if p_min_graduation_year is null and p_max_graduation_year is null
     and cardinality(p_allowed_degrees) = 0 and cardinality(p_required_certifications) = 0 then
    delete from public.opportunity_eligibility where opportunity_id = o.id;
  else
    insert into public.opportunity_eligibility(
      opportunity_id, min_graduation_year, max_graduation_year,
      allowed_degrees, required_certifications
    ) values (
      o.id, p_min_graduation_year, p_max_graduation_year,
      p_allowed_degrees, p_required_certifications
    )
    on conflict (opportunity_id) do update set
      min_graduation_year = excluded.min_graduation_year,
      max_graduation_year = excluded.max_graduation_year,
      allowed_degrees = excluded.allowed_degrees,
      required_certifications = excluded.required_certifications;
  end if;
  return o;
end
$update_admin_scholarship$;

create or replace function public.publish_admin_scholarship(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $publish_admin_scholarship$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  select * into o from public.opportunities
   where id = p_opportunity_id and type = 'SCHOLARSHIP'
   for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.status <> 'DRAFT' then
    raise exception 'OPPORTUNITY_NOT_DRAFT' using errcode = 'PT422';
  end if;
  if o.deadline is not null and o.deadline <= now() then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'ACTIVE', published_at = now()
   where id = o.id returning * into o;
  return o;
end
$publish_admin_scholarship$;

create or replace function public.close_admin_scholarship(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $close_admin_scholarship$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  select * into o from public.opportunities
   where id = p_opportunity_id and type = 'SCHOLARSHIP'
   for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_OPEN' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'CLOSED'
   where id = o.id returning * into o;
  return o;
end
$close_admin_scholarship$;

create or replace function public.list_admin_scholarship_applications(
  p_opportunity_id uuid default null,
  p_status text default 'ALL',
  p_limit integer default 25,
  p_before_applied_at timestamptz default null,
  p_before_id uuid default null
)
returns table (
  application_id uuid,
  opportunity_id uuid,
  scholarship_title text,
  is_sample boolean,
  graduate_id uuid,
  applicant_name text,
  cv_document_id uuid,
  personal_statement text,
  application_data jsonb,
  status text,
  applied_at timestamptz,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $list_admin_scholarship_applications$
declare v_uid uuid := public._require_uid();
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_status is null
     or p_status not in ('ALL','SUBMITTED','UNDER_REVIEW','ACCEPTED','REJECTED','WITHDRAWN')
     or p_limit is null or p_limit < 1 or p_limit > 100
     or ((p_before_applied_at is null) is distinct from (p_before_id is null)) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  return query
  select a.id, a.opportunity_id, o.title, o.is_sample, a.graduate_id,
         p.full_name, a.cv_document_id, a.personal_statement, a.application_data,
         a.status, a.applied_at, a.updated_at
    from public.scholarship_applications a
    join public.opportunities o on o.id = a.opportunity_id and o.type = 'SCHOLARSHIP'
    join public.profiles p on p.id = a.graduate_id
   where (p_opportunity_id is null or a.opportunity_id = p_opportunity_id)
     and (p_status = 'ALL' or a.status = p_status)
     and (p_before_applied_at is null or (a.applied_at, a.id) < (p_before_applied_at, p_before_id))
   order by a.applied_at desc, a.id desc
   limit p_limit;
end
$list_admin_scholarship_applications$;

create or replace function public.get_admin_scholarship_application(p_application_id uuid)
returns table (
  application_id uuid,
  opportunity_id uuid,
  scholarship_title text,
  is_sample boolean,
  graduate_id uuid,
  applicant_name text,
  applicant_college text,
  applicant_department text,
  applicant_major text,
  applicant_graduation_year integer,
  applicant_degree text,
  applicant_location text,
  cv_document_id uuid,
  cv_storage_path text,
  personal_statement text,
  application_data jsonb,
  status text,
  applied_at timestamptz,
  updated_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_admin_scholarship_application$
declare v_uid uuid := public._require_uid();
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_application_id is null or not exists (
    select 1
      from public.scholarship_applications a
      join public.opportunities o on o.id = a.opportunity_id
     where a.id = p_application_id and o.type = 'SCHOLARSHIP'
  ) then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404';
  end if;

  return query
  select a.id, a.opportunity_id, o.title, o.is_sample, a.graduate_id,
         p.full_name, gp.college, gp.department, gp.major, gp.graduation_year,
         gp.degree, gp.location, a.cv_document_id, cv.storage_path, a.personal_statement,
         a.application_data, a.status, a.applied_at, a.updated_at
    from public.scholarship_applications a
    join public.opportunities o on o.id = a.opportunity_id and o.type = 'SCHOLARSHIP'
    join public.profiles p on p.id = a.graduate_id
    join public.graduate_profiles gp on gp.profile_id = a.graduate_id
    left join public.cv_documents cv on cv.id = a.cv_document_id
   where a.id = p_application_id;
end
$get_admin_scholarship_application$;

create or replace function public.review_scholarship_application(
  p_application_id uuid,
  p_status text,
  p_note text default null
)
returns public.scholarship_applications
language plpgsql security definer set search_path = ''
as $review_scholarship_application$
declare
  v_uid uuid := public._require_uid();
  app public.scholarship_applications;
  o public.opportunities;
  v_body text;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_application_id is null
     or p_status is null or p_status not in ('UNDER_REVIEW','ACCEPTED','REJECTED')
     or (p_note is not null and length(p_note) > 1000) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select a.* into app
    from public.scholarship_applications a
    join public.opportunities op on op.id = a.opportunity_id and op.type = 'SCHOLARSHIP'
   where a.id = p_application_id
   for update of a;
  if not found then
    raise exception 'SCHOLARSHIP_APPLICATION_NOT_FOUND' using errcode = 'PT404';
  end if;
  select * into o from public.opportunities where id = app.opportunity_id;
  if o.is_sample then
    raise exception 'SAMPLE_DATA_NOT_REVIEWABLE' using errcode = 'PT422';
  end if;

  if not ((app.status = 'SUBMITTED' and p_status = 'UNDER_REVIEW')
       or (app.status = 'UNDER_REVIEW' and p_status in ('ACCEPTED','REJECTED'))) then
    raise exception 'INVALID_STATUS_TRANSITION' using errcode = 'PT422';
  end if;

  update public.scholarship_applications set status = p_status
   where id = app.id returning * into app;

  insert into public.scholarship_application_status_history(
    scholarship_application_id, old_status, new_status, source_type, actor_user_id, note
  ) values (
    app.id,
    case when p_status = 'UNDER_REVIEW' then 'SUBMITTED' else 'UNDER_REVIEW' end,
    p_status, 'ADMIN_ACTION', v_uid, nullif(btrim(coalesce(p_note,'')), '')
  );

  v_body := case p_status
    when 'UNDER_REVIEW' then 'بدأت مراجعة طلبك على «' || o.title || '».'
    when 'ACCEPTED' then 'تم قبول طلبك على «' || o.title || '».'
    when 'REJECTED' then 'تم رفض طلبك على «' || o.title || '».'
  end;
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (app.graduate_id, 'تحديث حالة طلب المنحة', v_body,
          'SCHOLARSHIP_APPLICATION_STATUS_UPDATED', app.id);
  return app;
end
$review_scholarship_application$;

revoke all on function public.create_admin_scholarship(text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[])
  from public, anon, authenticated;
revoke all on function public.update_admin_scholarship(uuid, text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[])
  from public, anon, authenticated;
revoke all on function public.publish_admin_scholarship(uuid) from public, anon, authenticated;
revoke all on function public.close_admin_scholarship(uuid) from public, anon, authenticated;
revoke all on function public.list_admin_scholarship_applications(uuid, text, integer, timestamptz, uuid)
  from public, anon, authenticated;
revoke all on function public.get_admin_scholarship_application(uuid) from public, anon, authenticated;
revoke all on function public.review_scholarship_application(uuid, text, text)
  from public, anon, authenticated;

grant execute on function public.create_admin_scholarship(text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[]),
  public.update_admin_scholarship(uuid, text, text, text, text, text, timestamptz, text[], integer, integer, text[], text[]),
  public.publish_admin_scholarship(uuid),
  public.close_admin_scholarship(uuid),
  public.list_admin_scholarship_applications(uuid, text, integer, timestamptz, uuid),
  public.get_admin_scholarship_application(uuid),
  public.review_scholarship_application(uuid, text, text)
to authenticated;

comment on table public.scholarship_applications is
  'Internal Alumni Connect scholarship applications. Platform admins publish scholarships, review applications and record decisions; no external provider delivery is implied.';
comment on column public.scholarship_application_status_history.source_type is
  'GRADUATE_ACTION records applicant actions; ADMIN_ACTION records central platform-admin review decisions.';
