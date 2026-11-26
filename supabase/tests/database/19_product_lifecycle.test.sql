-- 0019: approved product lifecycle for JOB/INTERNSHIP applications and TRAINING FIFO waitlists.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_key text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_key
$f$;

create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;

create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

create function tests.as_user(p_uid uuid, p_sql text) returns text language sql immutable as $f$
  select format('select set_config(%L, %L, true); select set_config(%L, %L, true); ',
    'request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text,
    'role', 'authenticated') || p_sql
$f$;

create function tests.mk_training(p_key text, p_capacity integer, p_waitlist boolean) returns uuid
language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities
    (seed_key, type, title, status, deadline, capacity, waitlist_enabled, attendance_mode)
  values
    ('w-' || p_key, 'TRAINING', 'Training ' || p_key, 'ACTIVE',
     now() + interval '7 days', p_capacity, p_waitlist, 'ONLINE')
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end $f$;

-- Helper RPCs capture IDs while keeping auth.uid() bound to the simulated caller.
create function tests.mk_company() returns uuid
language plpgsql security definer set search_path = '' as $f$
declare c public.companies;
begin
  c := public.create_company('Lifecycle Test Company', null, 'Synthetic company for lifecycle tests');
  insert into tests.ids values ('company', c.id);
  return c.id;
end $f$;

create function tests.mk_job(p_key text) returns uuid
language plpgsql security definer set search_path = '' as $f$
declare o public.opportunities;
begin
  o := public.create_company_job(tests.id('company'), 'Lifecycle Job', 'Synthetic job description');
  insert into tests.ids values (p_key, o.id);
  return o.id;
end $f$;

create function tests.mk_internship(p_key text) returns uuid
language plpgsql security definer set search_path = '' as $f$
declare o public.opportunities;
begin
  o := public.create_company_internship(tests.id('company'), 'Lifecycle Internship', 'Synthetic internship description');
  insert into tests.ids values (p_key, o.id);
  return o.id;
end $f$;

create function tests.mk_cv() returns uuid
language plpgsql security definer set search_path = '' as $f$
declare v uuid;
begin
  insert into public.cv_documents(graduate_id, storage_path, file_type, size_bytes, is_active)
  values (tests.id('candidate'), tests.id('candidate')::text || '/lifecycle.pdf', 'pdf', 2048, true)
  returning id into v;
  insert into tests.ids values ('cv', v);
  return v;
end $f$;

create function tests.apply(p_key text, p_opportunity_key text, p_cv_key text default null) returns uuid
language plpgsql security definer set search_path = '' as $f$
declare a public.applications; v_cv uuid;
begin
  if p_cv_key is not null then v_cv := tests.id(p_cv_key); end if;
  a := public.apply_for_job(tests.id(p_opportunity_key), v_cv, null);
  insert into tests.ids values (p_key, a.id);
  return a.id;
end $f$;

-- ---- Users and training fixtures -------------------------------------------------------------------
select tests.mk_user('u1');
select tests.mk_user('u2');
select tests.mk_user('u3');
select tests.mk_user('u4');
select tests.mk_user('u5');
select tests.mk_user('u6');
select tests.mk_user('u7');
select tests.mk_user('u8');
select tests.mk_user('u9');
select tests.mk_user('u10');
select tests.mk_training('fifo_training', 1, true);
select tests.mk_training('eligibility_training', 1, true);
select tests.mk_training('closed_training', 1, true);
select tests.mk_training('waitlist_cancel_training', 1, true);

-- ---- FIFO: oldest waitlisted user receives the next available seat --------------------------------
select tests.login('u1');
select is((public.register_for_event(tests.id('fifo_training'))).status, 'REGISTERED',
  'first training participant receives the only confirmed seat');
reset role;
select tests.login('u2');
select is((public.register_for_event(tests.id('fifo_training'))).status, 'WAITLISTED',
  'second participant joins the waitlist');
reset role;
select tests.login('u3');
select is((public.register_for_event(tests.id('fifo_training'))).status, 'WAITLISTED',
  'third participant joins behind the second');
reset role;
update public.event_registrations set registered_at = now() - interval '3 minutes'
 where opportunity_id = tests.id('fifo_training') and graduate_id = tests.id('u2');
update public.event_registrations set registered_at = now() - interval '2 minutes'
 where opportunity_id = tests.id('fifo_training') and graduate_id = tests.id('u3');

select tests.login('u1');
select is((public.cancel_event_registration(tests.id('fifo_training'))).status, 'CANCELLED',
  'confirmed participant cancellation succeeds');
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('fifo_training') and graduate_id = tests.id('u2')), 'REGISTERED',
  'the oldest waitlisted participant is automatically promoted');
select is((select status from public.event_registrations
  where opportunity_id = tests.id('fifo_training') and graduate_id = tests.id('u3')), 'WAITLISTED',
  'the next participant remains in the waitlist');
select is((select registered_count from public.opportunities where id = tests.id('fifo_training')), 1,
  'promotion restores the confirmed registration counter to capacity');
select is((select count(*)::int from public.notifications
  where profile_id = tests.id('u2') and type = 'TRAINING_WAITLIST_PROMOTED'), 1,
  'promotion creates an in-app notification for the promoted participant');
select is((select count(*)::int from public.event_registration_status_history h
  join public.event_registrations r on r.id = h.registration_id
  where r.opportunity_id = tests.id('fifo_training') and r.graduate_id = tests.id('u2')
    and h.old_status = 'WAITLISTED' and h.new_status = 'REGISTERED' and h.source_type = 'SYSTEM'), 1,
  'automatic FIFO promotion is recorded as a SYSTEM history transition');

select tests.login('u2');
select is((public.cancel_event_registration(tests.id('fifo_training'))).status, 'CANCELLED',
  'a promoted participant can cancel their confirmed seat');
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('fifo_training') and graduate_id = tests.id('u3')), 'REGISTERED',
  'the next FIFO participant is promoted after the next confirmed cancellation');

-- ---- FIFO skips newly ineligible waitlisted candidates, promoting the oldest eligible participant ----
select tests.login('u4');
select is((public.register_for_event(tests.id('eligibility_training'))).status, 'REGISTERED',
  'eligibility case: first participant receives the seat');
reset role;
select tests.login('u5');
select is((public.register_for_event(tests.id('eligibility_training'))).status, 'WAITLISTED',
  'eligibility case: second participant joins the waitlist');
reset role;
select tests.login('u6');
select is((public.register_for_event(tests.id('eligibility_training'))).status, 'WAITLISTED',
  'eligibility case: third participant joins the waitlist');
reset role;
update public.graduate_profiles set graduation_year = 2014 where profile_id = tests.id('u5');
update public.graduate_profiles set graduation_year = 2025 where profile_id = tests.id('u6');
insert into public.opportunity_eligibility(opportunity_id, min_graduation_year)
values (tests.id('eligibility_training'), 2020);
update public.event_registrations set registered_at = now() - interval '3 minutes'
 where opportunity_id = tests.id('eligibility_training') and graduate_id = tests.id('u5');
update public.event_registrations set registered_at = now() - interval '2 minutes'
 where opportunity_id = tests.id('eligibility_training') and graduate_id = tests.id('u6');
select tests.login('u4');
select public.cancel_event_registration(tests.id('eligibility_training'));
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('eligibility_training') and graduate_id = tests.id('u5')), 'WAITLISTED',
  'an ineligible waitlisted user is not promoted or silently removed');
select is((select status from public.event_registrations
  where opportunity_id = tests.id('eligibility_training') and graduate_id = tests.id('u6')), 'REGISTERED',
  'the oldest eligible waitlisted user is promoted after skipping an ineligible user');

-- ---- Closed training never promotes ----------------------------------------------------------------
select tests.login('u7');
select is((public.register_for_event(tests.id('closed_training'))).status, 'REGISTERED',
  'closed-training case starts with one confirmed participant');
reset role;
select tests.login('u8');
select is((public.register_for_event(tests.id('closed_training'))).status, 'WAITLISTED',
  'closed-training case has a queued participant');
reset role;
update public.opportunities set status = 'CLOSED' where id = tests.id('closed_training');
select tests.login('u7');
select public.cancel_event_registration(tests.id('closed_training'));
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('closed_training') and graduate_id = tests.id('u8')), 'WAITLISTED',
  'a closed training does not promote queued participants');
select is((select registered_count from public.opportunities where id = tests.id('closed_training')), 0,
  'a closed training still decrements the cancelled confirmed seat');

-- ---- Cancelling a waitlisted row frees no seat ------------------------------------------------------
select tests.login('u9');
select is((public.register_for_event(tests.id('waitlist_cancel_training'))).status, 'REGISTERED',
  'waitlist-cancellation case starts with a confirmed participant');
reset role;
select tests.login('u10');
select is((public.register_for_event(tests.id('waitlist_cancel_training'))).status, 'WAITLISTED',
  'waitlist-cancellation case has one queued participant');
select is((public.cancel_event_registration(tests.id('waitlist_cancel_training'))).status, 'CANCELLED',
  'a waitlisted participant can cancel their own queue entry');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('waitlist_cancel_training')), 1,
  'cancelling a waitlisted participant does not free the occupied seat');
select is((select status from public.event_registrations
  where opportunity_id = tests.id('waitlist_cancel_training') and graduate_id = tests.id('u9')), 'REGISTERED',
  'the confirmed participant remains registered');

-- ---- Company/internship setup -----------------------------------------------------------------------
select tests.mk_user('owner');
select tests.mk_user('candidate');
select tests.mk_user('viewer');
select tests.login('owner');
select tests.mk_company();
reset role;
update public.companies set verification_status = 'VERIFIED' where id = tests.id('company');
insert into public.company_memberships(company_id, user_id, role, is_active)
values (tests.id('company'), tests.id('viewer'), 'VIEWER', true);

select tests.login('owner');
select tests.mk_job('job');
select tests.mk_internship('internship');
select is((select type from public.opportunities where id = tests.id('internship')), 'INTERNSHIP',
  'company can create an explicit INTERNSHIP opportunity');
select is((select (public.set_opportunity_cv_requirement(tests.id('internship'), true)).requires_cv), true,
  'a verified company can require a CV on its draft internship');
select (public.publish_company_job(tests.id('job'))).id;
select (public.publish_company_job(tests.id('internship'))).id;
reset role;
select is((select requires_cv from public.opportunities where id = tests.id('job')), false,
  'CV remains optional by default on a JOB');

-- ---- Applications: optional CV for jobs, required per opportunity for internship --------------------
select tests.login('candidate');
select tests.apply('job_application', 'job', null);
reset role;
select throws_ok(
  tests.as_user(tests.id('candidate'), format('select public.apply_for_job(%L)', tests.id('internship'))),
  'PT422', 'CV_REQUIRED',
  'an internship configured to require a CV rejects an application without one'
);
select tests.mk_cv();
select tests.login('candidate');
select tests.apply('internship_application', 'internship', 'cv');
reset role;
select is((select cv_document_id from public.applications where id = tests.id('internship_application')),
  tests.id('cv'), 'application stores the candidate-owned active CV');

-- VIEWER is read-only; a direct jump from SUBMITTED to INTERVIEW is rejected.
select throws_ok(
  tests.as_user(tests.id('viewer'), format('select public.update_application_status(%L, %L)',
    tests.id('job_application'), 'UNDER_REVIEW')),
  'PT403', 'NOT_COMPANY_MEMBER',
  'company VIEWER cannot process applications'
);
select throws_ok(
  tests.as_user(tests.id('owner'), format('select public.update_application_status(%L, %L)',
    tests.id('job_application'), 'INTERVIEW')),
  'PT422', 'INVALID_STATUS_TRANSITION',
  'company cannot skip the UNDER_REVIEW and SHORTLISTED stages'
);
reset role;

-- The required transition path is SUBMITTED -> UNDER_REVIEW -> SHORTLISTED -> INTERVIEW -> ACCEPTED.
select tests.login('owner');
select is((public.update_application_status(tests.id('job_application'), 'UNDER_REVIEW')).status,
  'UNDER_REVIEW', 'company moves application to UNDER_REVIEW');
select is((public.update_application_status(tests.id('job_application'), 'SHORTLISTED')).status,
  'SHORTLISTED', 'company moves application to SHORTLISTED');
select is((public.update_application_status(tests.id('job_application'), 'INTERVIEW')).status,
  'INTERVIEW', 'company moves application to INTERVIEW');
select is((public.update_application_status(tests.id('job_application'), 'ACCEPTED')).status,
  'ACCEPTED', 'company moves application to ACCEPTED');
reset role;
select is((select count(*)::int from public.application_status_history
  where application_id = tests.id('job_application')
    and actor_user_id = tests.id('owner') and source_type = 'COMPANY_ACTION'), 4,
  'each company status change writes actor-attributed history');

select throws_ok(
  tests.as_user(tests.id('candidate'), format('select public.withdraw_application(%L)', tests.id('job_application'))),
  'PT422', 'CANNOT_WITHDRAW',
  'an ACCEPTED application is terminal and cannot be withdrawn'
);

-- Candidate can withdraw after the company has progressed the internship application to UNDER_REVIEW.
select tests.login('owner');
select is((public.update_application_status(tests.id('internship_application'), 'UNDER_REVIEW')).status,
  'UNDER_REVIEW', 'company moves internship application to UNDER_REVIEW');
reset role;
select tests.login('candidate');
select is((public.withdraw_application(tests.id('internship_application'))).status, 'WITHDRAWN',
  'candidate may withdraw from a non-terminal UNDER_REVIEW application');
reset role;
select is((select old_status from public.application_status_history
  where application_id = tests.id('internship_application') and new_status = 'WITHDRAWN'),
  'UNDER_REVIEW', 'withdrawal history preserves the actual previous status');
select throws_ok(
  tests.as_user(tests.id('candidate'), format('select public.apply_for_job(%L, %L)',
    tests.id('internship'), tests.id('cv'))),
  'PT409', 'ALREADY_APPLIED',
  'a withdrawn application cannot be submitted again');

select is((select status_source from public.applications where id = tests.id('job_application')),
  'COMPANY_ACTION', 'company decisions are recorded with COMPANY_ACTION source');

-- ---- Registration retry: only the exact pending phone + keyed National-ID pair may resume ----------
do $pending_retry$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, phone, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', '+201011110001',
          jsonb_build_object('full_name', 'Pending retry synthetic'));
  insert into tests.ids values ('pending_retry', v);
end
$pending_retry$;
set role service_role;
select public.record_identity_verification(
  tests.id('pending_retry'), 'synthetic-test-provider', 'synthetic:retry',
  repeat('e', 64), '0001',
  '[{"identity_type":"STUDENT","institution_ref":"SYNTHETIC_RETRY_INSTITUTION"}]'::jsonb,
  'VERIFIED', null
);
select is(
  public.find_pending_registration_retry('+201011110001', repeat('e', 64)),
  tests.id('pending_retry'),
  'service-role retry lookup resolves the exact matching pending account'
);
select ok(
  public.find_pending_registration_retry('+201011110002', repeat('e', 64)) is null,
  'retry lookup refuses a different phone'
);
select ok(
  public.find_pending_registration_retry('+201011110001', repeat('f', 64)) is null,
  'retry lookup refuses a different National-ID digest'
);
select is(
  has_function_privilege('authenticated', 'public.find_pending_registration_retry(text,text)', 'execute'),
  false,
  'authenticated clients cannot enumerate pending registration identities'
);
update public.profiles set account_status = 'ACTIVE' where id = tests.id('pending_retry');
select ok(
  public.find_pending_registration_retry('+201011110001', repeat('e', 64)) is null,
  'an already-active account cannot enter the pending OTP retry path'
);
reset role;

-- ---- Partial Auth signup recovery: only unlinked PENDING phone profiles can be claimed -----------
do $orphan_retry$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, phone, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', '+201011110002',
          jsonb_build_object('full_name', 'Orphaned pending synthetic'));
  insert into tests.ids values ('orphan_retry', v);
end
$orphan_retry$;
set role service_role;
select is(
  public.find_unlinked_pending_registration_retry('+201011110002'),
  tests.id('orphan_retry'),
  'provider-verified retry can recover an Auth-created profile with no identity ledger'
);
select ok(
  public.find_unlinked_pending_registration_retry('+201011110003') is null,
  'unlinked retry lookup does not resolve another phone'
);
select is(
  has_function_privilege('authenticated', 'public.find_unlinked_pending_registration_retry(text)', 'execute'),
  false,
  'authenticated clients cannot enumerate unlinked pending Auth accounts'
);
select public.record_identity_verification(
  tests.id('orphan_retry'), 'synthetic-test-provider', 'synthetic:orphan',
  repeat('f', 64), '0002',
  '[{"identity_type":"GRADUATE","institution_ref":"SYNTHETIC_RETRY_INSTITUTION"}]'::jsonb,
  'VERIFIED', null
);
select is(
  public.find_pending_registration_retry('+201011110002', repeat('f', 64)),
  tests.id('orphan_retry'),
  'recovered Auth account is now bound to the exact verified identity digest'
);
reset role;

-- ---- CV Storage cleanup: failure is delayed, observable and explicitly recoverable ----------------
insert into private.cv_cleanup_queue (storage_path, graduate_id, reason, status, attempts, next_attempt_at)
values ('synthetic-cleanup-retry/cv.pdf', tests.id('candidate'), 'METADATA_DELETE', 'PENDING', 0, now() - interval '1 minute');
set role service_role;
select is(
  jsonb_array_length(public.claim_cv_cleanup(10)),
  1,
  'cleanup worker can claim a due item'
);
select is(
  public.fail_cv_cleanup(
    (select id from private.cv_cleanup_queue where storage_path = 'synthetic-cleanup-retry/cv.pdf'),
    'STORAGE_DELETE_FAILED'
  ),
  true,
  'failed Storage deletion is durably recorded'
);
select is(
  jsonb_array_length(public.claim_cv_cleanup(10)),
  0,
  'a failed cleanup is not reclaimed immediately before its backoff expires'
);
select is(
  public.retry_cv_cleanup(
    (select id from private.cv_cleanup_queue where storage_path = 'synthetic-cleanup-retry/cv.pdf')
  ),
  true,
  'an operator can explicitly requeue a failed cleanup item'
);
select is(
  jsonb_array_length(public.claim_cv_cleanup(10)),
  1,
  'an explicitly requeued cleanup item is claimable again'
);
select is(
  public.complete_cv_cleanup(
    (select id from private.cv_cleanup_queue where storage_path = 'synthetic-cleanup-retry/cv.pdf')
  ),
  true,
  'a retried cleanup item can be completed'
);
select is(
  (select status from private.cv_cleanup_queue where storage_path = 'synthetic-cleanup-retry/cv.pdf'),
  'DONE',
  'successful retry leaves a durable DONE record'
);
reset role;

-- ---- Company verification changes invalidate recommendations and hide suspended listings --------
update public.graduate_profiles
   set recommendations_dirty = false
 where profile_id = tests.id('candidate');
update public.companies
   set verification_status = 'SUSPENDED'
 where id = tests.id('company');
select is(
  (select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('candidate')),
  true,
  'suspending a company invalidates the recommendation cache'
);
set role service_role;
select is(
  (select count(*)::int
     from jsonb_array_elements(
       public.get_recommendation_candidates(tests.id('candidate')) -> 'opportunities'
     ) item
    where item ->> 'id' in (tests.id('job')::text, tests.id('internship')::text)),
  0,
  'suspended company opportunities are excluded from fresh recommendation candidates'
);
reset role;
select throws_ok(
  tests.as_user(tests.id('owner'), format(
    'select public.update_company_job(%L, %L, %L)',
    tests.id('job'), 'Blocked while suspended', 'A sufficiently long description for this test'
  )),
  'PT422', 'COMPANY_NOT_VERIFIED',
  'company members cannot edit an ACTIVE listing while the company is suspended'
);

select * from finish();
rollback;
