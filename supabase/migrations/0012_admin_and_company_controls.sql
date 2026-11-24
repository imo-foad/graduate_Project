-- 0012: platform-admin job controls, company team management and status transition guards.

create or replace function public.set_company_member(
  p_company_id uuid,
  p_user_id uuid,
  p_role text,
  p_is_active boolean default true
)
returns public.company_memberships
language plpgsql security definer set search_path = ''
as $set_company_member$
declare v_uid uuid := public._require_uid(); m public.company_memberships;
begin
  if not private.is_company_member(p_company_id, array['OWNER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if p_user_id is null or p_user_id = v_uid
     or p_role is null or p_role not in ('RECRUITER','VIEWER')
     or p_is_active is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'USER_NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_is_active then
    insert into public.company_memberships(company_id, user_id, role, is_active)
    values (p_company_id, p_user_id, p_role, true)
    on conflict (company_id, user_id) do update
      set role = excluded.role, is_active = true
    returning * into m;
  else
    update public.company_memberships
       set is_active = false
     where company_id = p_company_id and user_id = p_user_id
       and role <> 'OWNER'
    returning * into m;
    if not found then raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'PT404'; end if;
  end if;
  return m;
end
$set_company_member$;

create or replace function public.create_admin_job(
  p_title text,
  p_company_name text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null,
  p_employment_type text default 'FULL_TIME',
  p_experience_level text default 'FRESH_GRADUATE'
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $create_admin_job$
declare v_uid uuid := public._require_uid(); o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if length(btrim(coalesce(p_title,''))) < 3
     or length(btrim(coalesce(p_company_name,''))) < 2
     or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or p_employment_type is null or p_employment_type not in ('FULL_TIME','PART_TIME','CONTRACT','INTERNSHIP')
     or p_experience_level is null or p_experience_level not in ('FRESH_GRADUATE','JUNIOR','MID','SENIOR')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.opportunities(
    seed_key, type, title, company_name, description, location, attendance_mode,
    status, deadline, is_sample, created_by
  ) values (
    'admin-' || gen_random_uuid()::text, 'JOB', btrim(p_title), btrim(p_company_name),
    p_description, nullif(btrim(coalesce(p_location,'')), ''), p_attendance_mode,
    'DRAFT', p_deadline, false, v_uid
  ) returning * into o;
  insert into public.job_details(opportunity_id, employment_type, experience_level)
  values (o.id, p_employment_type, p_experience_level);
  return o;
end
$create_admin_job$;

create or replace function public.update_admin_job(
  p_opportunity_id uuid,
  p_title text,
  p_company_name text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null
)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $update_admin_job$
declare o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.type <> 'JOB' then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_EDITABLE' using errcode = 'PT422';
  end if;
  if length(btrim(coalesce(p_title,''))) < 3
     or length(btrim(coalesce(p_company_name,''))) < 2
     or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  update public.opportunities set title = btrim(p_title), company_name = btrim(p_company_name),
    description = p_description, location = nullif(btrim(coalesce(p_location,'')), ''),
    attendance_mode = p_attendance_mode, deadline = p_deadline
  where id = o.id returning * into o;
  return o;
end
$update_admin_job$;

create or replace function public.publish_admin_job(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $publish_admin_job$
declare o public.opportunities; v_company_status text;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.type <> 'JOB' then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if o.status <> 'DRAFT' then
    raise exception 'OPPORTUNITY_NOT_DRAFT' using errcode = 'PT422';
  end if;
  if o.company_id is not null then
    select verification_status into v_company_status
      from public.companies where id = o.company_id;
    if v_company_status <> 'VERIFIED' then
      raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
    end if;
  end if;
  if o.deadline is not null and o.deadline <= now() then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'ACTIVE', published_at = now()
   where id = o.id returning * into o;
  return o;
end
$publish_admin_job$;

create or replace function public.close_admin_job(p_opportunity_id uuid)
returns public.opportunities
language plpgsql security definer set search_path = ''
as $close_admin_job$
declare o public.opportunities;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found or o.type <> 'JOB' then
    raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404';
  end if;
  if o.status not in ('DRAFT','ACTIVE') then
    raise exception 'OPPORTUNITY_NOT_OPEN' using errcode = 'PT422';
  end if;
  update public.opportunities set status = 'CLOSED' where id = o.id returning * into o;
  return o;
end
$close_admin_job$;

-- Employer/admin application updates follow a monotonic hiring pipeline.
create or replace function public.update_application_status(
  p_application_id uuid, p_status text, p_note text default null
)
returns public.applications
language plpgsql security definer set search_path = ''
as $update_application_status_v2$
declare
  v_uid uuid := public._require_uid();
  a public.applications;
  o public.opportunities;
  v_old_status text;
  v_source text;
begin
  if p_status is null or p_status not in ('UNDER_REVIEW','SHORTLISTED','INTERVIEW','ACCEPTED','REJECTED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into a from public.applications where id = p_application_id for update;
  if not found then raise exception 'APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into o from public.opportunities where id = a.opportunity_id;
  if private.is_platform_admin() then
    v_source := 'ADMIN_ACTION';
  elsif o.company_id is not null
     and private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[]) then
    v_source := 'COMPANY_ACTION';
  else
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if a.status_source = 'SEED_SAMPLE' or a.status = 'WITHDRAWN'
     or a.status in ('ACCEPTED','REJECTED') then
    raise exception 'APPLICATION_NOT_UPDATABLE' using errcode = 'PT422';
  end if;
  v_old_status := a.status;
  if not (
    (v_old_status = 'SUBMITTED' and p_status in ('UNDER_REVIEW','REJECTED'))
    or (v_old_status = 'UNDER_REVIEW' and p_status in ('SHORTLISTED','INTERVIEW','REJECTED'))
    or (v_old_status = 'SHORTLISTED' and p_status in ('INTERVIEW','REJECTED'))
    or (v_old_status = 'INTERVIEW' and p_status in ('ACCEPTED','REJECTED'))
  ) then
    raise exception 'INVALID_STATUS_TRANSITION' using errcode = 'PT422';
  end if;
  update public.applications set status = p_status, status_source = v_source
   where id = a.id returning * into a;
  insert into public.application_status_history(application_id, old_status, new_status, source_type, actor_user_id, note)
  values (a.id, v_old_status, p_status, v_source, v_uid, nullif(btrim(coalesce(p_note,'')), ''));
  insert into public.notifications(profile_id, title, body, type, related_entity_id)
  values (a.graduate_id, 'تحديث حالة طلب التوظيف',
          'تم تحديث حالة طلبك على «' || o.title || '» إلى: ' || p_status || '.',
          'APPLICATION_STATUS_UPDATED', a.id);
  return a;
end
$update_application_status_v2$;

revoke all on function public.set_company_member(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.create_admin_job(text, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.update_admin_job(uuid, text, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.publish_admin_job(uuid) from public, anon, authenticated;
revoke all on function public.close_admin_job(uuid) from public, anon, authenticated;

grant execute on function public.set_company_member(uuid, uuid, text, boolean),
  public.create_admin_job(text, text, text, text, text, timestamptz, text, text),
  public.update_admin_job(uuid, text, text, text, text, text, timestamptz),
  public.publish_admin_job(uuid), public.close_admin_job(uuid)
to authenticated;

comment on function public.set_company_member(uuid, uuid, text, boolean) is 'Company OWNER manages recruiter/viewer memberships; no client can create an OWNER.';
comment on function public.update_application_status(uuid, text, text) is 'Company recruiters or platform admins can advance applications through the allowed hiring state machine.';
