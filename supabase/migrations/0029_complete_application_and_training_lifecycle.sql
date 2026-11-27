-- 0029: complete job/internship applications and FIFO training waitlist rules.
--
-- Product decisions 2026-11-26:
--   * JOB and INTERNSHIP share the same application lifecycle and transition rules.
--   * CV is optional by default; only a verified company may require it on a specific draft opportunity.
--   * candidates may withdraw from any non-terminal application state; WITHDRAWN is terminal.
--   * Training registrations use FIFO waitlist promotion inside the cancellation transaction.
--
-- Forward-only. No historical rows are deleted and the legacy RPC names remain compatible.

-- ---------------------------------------------------------------------------------------------------
-- 1. Per-opportunity CV requirement (off by default).
-- ---------------------------------------------------------------------------------------------------
alter table public.opportunities
  add column if not exists requires_cv boolean not null default false;

comment on column public.opportunities.requires_cv is
  'When true, an active CV owned by the candidate is required for JOB/INTERNSHIP applications. Default false.';

-- Registration history is append-only. The current row remains the read model; this table records
-- candidate actions and automatic FIFO promotions for audit and support.
create table public.event_registration_status_history (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null references public.event_registrations(id) on delete cascade,
  old_status text check (old_status is null or old_status in ('REGISTERED','WAITLISTED','CANCELLED')),
  new_status text not null check (new_status in ('REGISTERED','WAITLISTED','CANCELLED')),
  actor_user_id uuid references auth.users(id) on delete set null,
  source_type text not null check (source_type in ('CANDIDATE','SYSTEM','SEED')),
  changed_at timestamptz not null default now(),
  note text
);
create index event_registration_history_row_idx
  on public.event_registration_status_history(registration_id, changed_at, id);
alter table public.event_registration_status_history enable row level security;
revoke all on public.event_registration_status_history from public, anon, authenticated;
grant select on public.event_registration_status_history to authenticated;
create policy event_registration_history_select_own
  on public.event_registration_status_history for select to authenticated
  using (exists (
    select 1 from public.event_registrations r
     where r.id = registration_id and r.graduate_id = (select auth.uid())
  ));
insert into public.event_registration_status_history
  (registration_id, old_status, new_status, actor_user_id, source_type, changed_at, note)
select r.id, null, r.status, null,
       case when r.source = 'SEED_SAMPLE' then 'SEED' else 'CANDIDATE' end,
       r.registered_at, 'Backfilled current status when registration history was introduced'
  from public.event_registrations r;
comment on table public.event_registration_status_history is
  'Append-only status audit for Training registrations, including system FIFO promotions.';

create or replace function public.set_opportunity_cv_requirement(
  p_opportunity_id uuid,
  p_required boolean
) returns public.opportunities
language plpgsql security definer set search_path = ''
as $set_opportunity_cv_requirement$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  v_company_status text;
begin
  if p_opportunity_id is null or p_required is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type not in ('JOB','INTERNSHIP') then
    raise exception 'NOT_APPLICATION_OPPORTUNITY' using errcode = 'PT422';
  end if;
  if o.status <> 'DRAFT' then
    raise exception 'OPPORTUNITY_NOT_DRAFT' using errcode = 'PT422';
  end if;
  if o.company_id is null or (
       not private.is_platform_admin()
       and not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[])
     ) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  select verification_status into v_company_status
    from public.companies where id = o.company_id;
  if v_company_status is distinct from 'VERIFIED' then
    raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
  end if;
  update public.opportunities set requires_cv = p_required
   where id = o.id returning * into o;
  return o;
end $set_opportunity_cv_requirement$;
revoke all on function public.set_opportunity_cv_requirement(uuid, boolean) from public, anon, authenticated;
grant execute on function public.set_opportunity_cv_requirement(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 2. Explicit company internship creation. Existing update/publish/close RPCs already operate on any
--    company-owned opportunity, so they remain compatible with both JOB and INTERNSHIP.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.create_company_internship(
  p_company_id uuid,
  p_title text,
  p_description text,
  p_location text default null,
  p_attendance_mode text default 'ONSITE',
  p_deadline timestamptz default null,
  p_experience_level text default 'FRESH_GRADUATE'
) returns public.opportunities
language plpgsql security definer set search_path = ''
as $create_company_internship$
declare
  v_uid uuid := public._require_uid();
  c public.companies;
  o public.opportunities;
begin
  if not private.is_company_member(p_company_id, array['OWNER','RECRUITER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  select * into c from public.companies where id = p_company_id for share;
  if not found then raise exception 'COMPANY_NOT_FOUND' using errcode = 'PT404'; end if;
  if length(btrim(coalesce(p_title,''))) < 3
     or length(btrim(coalesce(p_description,''))) < 10
     or p_attendance_mode is null or p_attendance_mode not in ('ONSITE','ONLINE','HYBRID')
     or p_experience_level is null or p_experience_level not in ('FRESH_GRADUATE','JUNIOR','MID','SENIOR')
     or (p_deadline is not null and p_deadline <= now()) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into public.opportunities(
    seed_key, type, title, company_name, description, location, attendance_mode,
    status, deadline, is_sample, company_id, created_by
  ) values (
    'company-internship-' || gen_random_uuid()::text, 'INTERNSHIP', btrim(p_title), c.name,
    p_description, nullif(btrim(coalesce(p_location,'')), ''), p_attendance_mode,
    'DRAFT', p_deadline, false, p_company_id, v_uid
  ) returning * into o;
  insert into public.job_details(opportunity_id, employment_type, experience_level)
  values (o.id, 'INTERNSHIP', p_experience_level);
  return o;
end $create_company_internship$;
revoke all on function public.create_company_internship(uuid, text, text, text, text, timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.create_company_internship(uuid, text, text, text, text, timestamptz, text)
  to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 3. One application path for both JOB and INTERNSHIP. A CV must be active and owner-scoped when
--    supplied, and is mandatory only when the verified company set requires_cv before publication.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.apply_for_job(
  p_opportunity_id uuid,
  p_cv_document_id uuid default null,
  p_note text default null
) returns public.applications
language plpgsql security definer set search_path = ''
as $apply_for_job_v2$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  f text[];
  app public.applications;
begin
  if p_opportunity_id is null then raise exception 'INVALID_INPUT' using errcode = 'PT422'; end if;
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type not in ('JOB','INTERNSHIP') then
    raise exception 'NOT_APPLICATION_OPPORTUNITY' using errcode = 'PT422';
  end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at) then
    raise exception 'OPPORTUNITY_CLOSED' using errcode = 'PT422';
  end if;
  if o.company_id is not null and not exists (
    select 1 from public.companies c where c.id = o.company_id and c.verification_status = 'VERIFIED'
  ) then
    raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  if o.requires_cv and p_cv_document_id is null then
    raise exception 'CV_REQUIRED' using errcode = 'PT422';
  end if;
  if p_cv_document_id is not null and not exists (
    select 1 from public.cv_documents
     where id = p_cv_document_id and graduate_id = v_uid and is_active
  ) then
    raise exception 'CV_NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_note is not null and length(p_note) > 2000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  begin
    insert into public.applications (opportunity_id, graduate_id, cv_document_id, note)
    values (o.id, v_uid, p_cv_document_id, nullif(btrim(coalesce(p_note,'')), ''))
    returning * into app;
  exception when unique_violation then
    -- The unique (graduate_id, opportunity_id) key intentionally prevents reapplying after WITHDRAWN.
    raise exception 'ALREADY_APPLIED' using errcode = 'PT409';
  end;
  insert into public.application_status_history
    (application_id, old_status, new_status, source_type, actor_user_id, note)
  values (app.id, null, 'SUBMITTED', 'APP_ACTION', v_uid,
          nullif(btrim(coalesce(p_note,'')), ''));
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم تقديم طلبك',
          'تم إرسال طلبك على «' || o.title || '».',
          'APPLICATION_SUBMITTED', app.id);
  return app;
end $apply_for_job_v2$;
revoke all on function public.apply_for_job(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.apply_for_job(uuid, uuid, text) to authenticated;
comment on function public.apply_for_job(uuid, uuid, text) is
  'Candidate application for JOB or INTERNSHIP. CV optional unless the verified company required it on the draft.';

-- ---------------------------------------------------------------------------------------------------
-- 4. Candidate withdrawal from any non-terminal stage. WITHDRAWN cannot be reopened/reapplied.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.withdraw_application(p_application_id uuid)
returns public.applications
language plpgsql security definer set search_path = ''
as $withdraw_application_v2$
declare
  v_uid uuid := public._require_uid();
  app public.applications;
  v_old_status text;
begin
  select * into app from public.applications
   where id = p_application_id and graduate_id = v_uid for update;
  if not found then raise exception 'APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if app.status_source = 'SEED_SAMPLE'
     or app.status not in ('SUBMITTED','UNDER_REVIEW','SHORTLISTED','INTERVIEW') then
    raise exception 'CANNOT_WITHDRAW' using errcode = 'PT422';
  end if;
  v_old_status := app.status;
  update public.applications set status = 'WITHDRAWN', status_source = 'APP_ACTION'
   where id = app.id returning * into app;
  insert into public.application_status_history
    (application_id, old_status, new_status, source_type, actor_user_id, note)
  values (app.id, v_old_status, 'WITHDRAWN', 'APP_ACTION', v_uid, 'Candidate withdrew');
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم سحب الطلب', 'تم سحب طلب التقديم الخاص بك.', 'APPLICATION_WITHDRAWN', app.id);
  return app;
end $withdraw_application_v2$;
revoke all on function public.withdraw_application(uuid) from public, anon, authenticated;
grant execute on function public.withdraw_application(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 5. Company/admin status changes obey the approved state machine. No skipping or reopening.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.update_application_status(
  p_application_id uuid,
  p_status text,
  p_note text default null
) returns public.applications
language plpgsql security definer set search_path = ''
as $update_application_status_v2$
declare
  v_uid uuid := public._require_uid();
  v_admin boolean := private.is_platform_admin();
  a public.applications;
  o public.opportunities;
  v_old_status text;
  v_source text;
  v_allowed boolean := false;
begin
  if p_status is null or p_status not in ('UNDER_REVIEW','SHORTLISTED','INTERVIEW','ACCEPTED','REJECTED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_note is not null and length(p_note) > 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into a from public.applications where id = p_application_id for update;
  if not found then raise exception 'APPLICATION_NOT_FOUND' using errcode = 'PT404'; end if;
  select * into o from public.opportunities where id = a.opportunity_id;
  if o.type not in ('JOB','INTERNSHIP') then
    raise exception 'NOT_APPLICATION_OPPORTUNITY' using errcode = 'PT422';
  end if;
  if not v_admin and (
       o.company_id is null
       or not private.is_company_member(o.company_id, array['OWNER','RECRUITER']::text[])
     ) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if not v_admin and not exists (
    select 1 from public.companies c where c.id = o.company_id and c.verification_status = 'VERIFIED'
  ) then
    raise exception 'COMPANY_NOT_VERIFIED' using errcode = 'PT422';
  end if;
  if a.status_source = 'SEED_SAMPLE' then
    raise exception 'APPLICATION_NOT_UPDATABLE' using errcode = 'PT422';
  end if;
  v_old_status := a.status;
  v_allowed := case v_old_status
    when 'SUBMITTED' then p_status in ('UNDER_REVIEW','REJECTED')
    when 'UNDER_REVIEW' then p_status in ('SHORTLISTED','REJECTED')
    when 'SHORTLISTED' then p_status in ('INTERVIEW','REJECTED')
    when 'INTERVIEW' then p_status in ('ACCEPTED','REJECTED')
    else false
  end;
  if not v_allowed then
    raise exception 'INVALID_STATUS_TRANSITION' using errcode = 'PT422';
  end if;
  v_source := case when v_admin then 'ADMIN_ACTION' else 'COMPANY_ACTION' end;
  update public.applications set status = p_status, status_source = v_source
   where id = a.id returning * into a;
  insert into public.application_status_history
    (application_id, old_status, new_status, source_type, actor_user_id, note)
  values (a.id, v_old_status, p_status, v_source, v_uid,
          nullif(btrim(coalesce(p_note,'')), ''));
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (a.graduate_id, 'تحديث حالة طلب التوظيف',
          'تم تحديث حالة طلبك على «' || o.title || '» إلى: ' || p_status || '.',
          'APPLICATION_STATUS_UPDATED', a.id);
  return a;
end $update_application_status_v2$;
revoke all on function public.update_application_status(uuid, text, text) from public, anon, authenticated;
grant execute on function public.update_application_status(uuid, text, text) to authenticated;
comment on function public.update_application_status(uuid, text, text) is
  'Company OWNER/RECRUITER or platform admin updates an application through the strict JOB/INTERNSHIP state machine.';

create or replace function public.register_for_event(p_opportunity_id uuid)
returns public.event_registrations
language plpgsql security definer set search_path = ''
as $register_for_training_v2$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  r public.event_registrations;
  f text[];
  v_status text;
  v_old_status text;
  v_existing boolean;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'TRAINING' then
    raise exception 'NOT_REGISTRABLE' using errcode = 'PT422';
  end if;
  if not public.is_opportunity_open(o.status, o.deadline, o.end_at)
     or (o.registration_opens_at is not null and o.registration_opens_at > now()) then
    raise exception 'REGISTRATION_CLOSED' using errcode = 'PT422';
  end if;
  f := public.eligibility_failures(v_uid, o.id);
  if cardinality(f) > 0 then
    raise exception 'NOT_ELIGIBLE' using errcode = 'PT422', detail = array_to_string(f, ',');
  end if;
  select * into r from public.event_registrations
   where graduate_id = v_uid and opportunity_id = o.id for update;
  v_existing := found;
  if v_existing and r.status <> 'CANCELLED' then
    raise exception 'ALREADY_REGISTERED' using errcode = 'PT409';
  end if;
  if o.capacity is null or o.registered_count < o.capacity then
    v_status := 'REGISTERED';
    update public.opportunities set registered_count = registered_count + 1 where id = o.id;
  elsif o.waitlist_enabled then
    v_status := 'WAITLISTED';
  else
    raise exception 'EVENT_FULL' using errcode = 'PT409';
  end if;
  if v_existing then
    v_old_status := r.status;
    update public.event_registrations set status = v_status, registered_at = now()
     where id = r.id returning * into r;
  else
    insert into public.event_registrations (opportunity_id, graduate_id, status)
    values (o.id, v_uid, v_status) returning * into r;
  end if;
  insert into public.event_registration_status_history
    (registration_id, old_status, new_status, actor_user_id, source_type, note)
  values (r.id, v_old_status, v_status, v_uid, 'CANDIDATE',
          case when v_existing then 'Candidate re-registered after cancellation' else 'Candidate registered' end);
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid,
          case when v_status = 'REGISTERED' then 'تم تسجيلك' else 'أنت في قائمة الانتظار' end,
          case when v_status = 'REGISTERED'
               then 'تم تسجيلك مباشرة في «' || o.title || '» (تدريب).'
               else 'البرنامج التدريبي «' || o.title || '» مكتمل العدد؛ تمت إضافتك إلى قائمة الانتظار (FIFO).' end,
          'TRAINING_REGISTERED', r.id);
  return r;
end $register_for_training_v2$;
revoke all on function public.register_for_event(uuid) from public, anon, authenticated;
grant execute on function public.register_for_event(uuid) to authenticated;
comment on function public.register_for_event(uuid) is
  'Direct TRAINING registration with status history (historical name kept for clients).';

-- ---------------------------------------------------------------------------------------------------
-- 6. FIFO training waitlist promotion in the same transaction as a confirmed cancellation.
--    Ineligible waitlisted users are skipped but remain WAITLISTED; the oldest eligible user is promoted.
--    A closed/cancelled training, unopened window, or disabled waitlist is never promoted.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.cancel_event_registration(p_opportunity_id uuid)
returns public.event_registrations
language plpgsql security definer set search_path = ''
as $cancel_training_registration_v2$
declare
  v_uid uuid := public._require_uid();
  o public.opportunities;
  r public.event_registrations;
  w public.event_registrations;
  f text[];
  v_old_status text;
  v_was_registered boolean := false;
begin
  select * into o from public.opportunities where id = p_opportunity_id for update;
  if not found then raise exception 'OPPORTUNITY_NOT_FOUND' using errcode = 'PT404'; end if;
  if o.type <> 'TRAINING' then
    raise exception 'NOT_REGISTRABLE' using errcode = 'PT422';
  end if;
  select * into r from public.event_registrations
   where graduate_id = v_uid and opportunity_id = o.id for update;
  if not found then raise exception 'REGISTRATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if r.status = 'CANCELLED' then raise exception 'ALREADY_CANCELLED' using errcode = 'PT409'; end if;
  v_old_status := r.status;
  v_was_registered := r.status = 'REGISTERED';

  if v_was_registered then
    update public.opportunities
       set registered_count = greatest(registered_count - 1, 0)
     where id = o.id
    returning * into o;
  end if;

  update public.event_registrations set status = 'CANCELLED'
   where id = r.id returning * into r;
  insert into public.event_registration_status_history
    (registration_id, old_status, new_status, actor_user_id, source_type, note)
  values (r.id, v_old_status, 'CANCELLED', v_uid, 'CANDIDATE', 'Candidate cancelled registration');
  insert into public.notifications (profile_id, title, body, type, related_entity_id)
  values (v_uid, 'تم إلغاء التسجيل', 'تم إلغاء تسجيلك في «' || o.title || '».',
          'TRAINING_CANCELLED', r.id);

  -- A WAITLISTED cancellation consumes no seat, so it cannot trigger promotion.
  if v_was_registered
     and o.registered_count < coalesce(o.capacity, o.registered_count + 1)
     and o.waitlist_enabled
     and o.status = 'ACTIVE'
     and public.is_opportunity_open(o.status, o.deadline, o.end_at)
     and (o.registration_opens_at is null or o.registration_opens_at <= now())
     and exists (
       select 1 from public.event_registrations er
        where er.opportunity_id = o.id and er.status = 'WAITLISTED'
     )
  then
    for w in
      select * from public.event_registrations er
       where er.opportunity_id = o.id and er.status = 'WAITLISTED'
       order by er.registered_at asc, er.id asc
       for update
    loop
      f := public.eligibility_failures(w.graduate_id, o.id);
      if coalesce(cardinality(f), 0) = 0 then
        update public.event_registrations set status = 'REGISTERED'
         where id = w.id;
        insert into public.event_registration_status_history
          (registration_id, old_status, new_status, actor_user_id, source_type, note)
        values (w.id, 'WAITLISTED', 'REGISTERED', null, 'SYSTEM', 'FIFO waitlist promotion after confirmed cancellation');
        update public.opportunities set registered_count = registered_count + 1
         where id = o.id returning * into o;
        insert into public.notifications (profile_id, title, body, type, related_entity_id)
        values (w.graduate_id, 'تم تأكيد مقعدك',
                'تم ترقية تسجيلك تلقائيًا من قائمة الانتظار إلى مقعد مؤكد في «' || o.title || '».',
                'TRAINING_WAITLIST_PROMOTED', w.id);
        exit;
      end if;
    end loop;
  end if;

  return r;
end $cancel_training_registration_v2$;
revoke all on function public.cancel_event_registration(uuid) from public, anon, authenticated;
grant execute on function public.cancel_event_registration(uuid) to authenticated;
comment on function public.cancel_event_registration(uuid) is
  'Cancels own TRAINING registration. A confirmed cancellation promotes the oldest eligible FIFO waitlisted user atomically.';
