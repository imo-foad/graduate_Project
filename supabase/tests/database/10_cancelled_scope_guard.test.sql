-- 0025: Scholarship (#14) and Competition (#15) are cancelled. These tests prove the deactivation is
-- enforced in the database and that the remaining catalogue still works. Historical data is retained.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

-- ---- 1. The single scope predicate -----------------------------------------------------------------
select is(public.is_opportunity_type_active('JOB'), true, 'JOB is in the active product scope');
select is(public.is_opportunity_type_active('INTERNSHIP'), true, 'INTERNSHIP is in the active product scope');
select is(public.is_opportunity_type_active('TRAINING'), true, 'TRAINING is in the active product scope');
select is(public.is_opportunity_type_active('EVENT'), true, 'EVENT is in the active product scope');
select is(public.is_opportunity_type_active('CONFERENCE'), true, 'CONFERENCE is in the active product scope');
select is(public.is_opportunity_type_active('VOLUNTEER'), true, 'VOLUNTEER is in the active product scope');
select is(public.is_opportunity_type_active('SCHOLARSHIP'), false, 'SCHOLARSHIP is cancelled');
select is(public.is_opportunity_type_active('COMPETITION'), false, 'COMPETITION is cancelled');
select is(public.is_opportunity_type_active(null), false, 'a null type is never active');
select is(public.is_opportunity_type_active('SOMETHING_NEW'), false, 'unknown types are not active');
select is(public.is_opportunity_type_active(''), false, 'an empty type is not active');
select is(public.is_opportunity_type_active('   '), false, 'a whitespace-only type is not active');
-- Parity contract mirrored in TypeScript (_shared/opportunity-state.ts): matching is case-sensitive and
-- exact, so these must stay rejected. Tests the current SQL behaviour; it does not change any rule.
select is(public.is_opportunity_type_active('job'), false, 'type matching is case-sensitive (lowercase job)');
select is(public.is_opportunity_type_active('Job'), false, 'type matching is case-sensitive (mixed-case Job)');
select is(public.is_opportunity_type_active('JOB '), false, 'types are not trimmed (trailing space)');
select is(public.is_opportunity_type_active(' JOB'), false, 'types are not trimmed (leading space)');
select is(public.is_opportunity_type_active('JOBS'), false, 'near-miss values are not active');

-- ---- 2. Seed data no longer ships live cancelled listings ------------------------------------------
select is(
  (select count(*)::int from public.opportunities
    where type in ('SCHOLARSHIP','COMPETITION') and status <> 'CANCELLED'),
  0,
  'no active SCHOLARSHIP/COMPETITION listing survives in the seeded catalogue'
);

-- ---- 3. No role may create a new cancelled-type listing ---------------------------------------------
select throws_ok(
  $$ insert into public.opportunities (seed_key, type, title, status)
     values ('t-scope-new-scholarship', 'SCHOLARSHIP', 'New scholarship', 'ACTIVE') $$,
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'creating a SCHOLARSHIP opportunity is rejected'
);
select throws_ok(
  $$ insert into public.opportunities (seed_key, type, title, status)
     values ('t-scope-new-competition', 'COMPETITION', 'New competition', 'ACTIVE') $$,
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'creating a COMPETITION opportunity is rejected'
);

-- ---- 4. A legacy row forced ACTIVE is still invisible to discovery and recommendations ---------------
-- Reproduces pre-0025 data that this migration has to neutralise. The guard trigger is disabled only
-- inside this transaction to emulate data that predates it.
alter table public.opportunities disable trigger opportunities_reject_cancelled_type;
create table tests.legacy (id uuid primary key);
with ins as (
  insert into public.opportunities (seed_key, type, title, status, deadline, capacity, waitlist_enabled, attendance_mode)
  values ('t-scope-legacy-scholarship', 'SCHOLARSHIP', 'Legacy scholarship', 'ACTIVE',
          now() + interval '5 days', 10, false, 'ONLINE')
  returning id
)
insert into tests.legacy select id from ins;
alter table public.opportunities enable trigger opportunities_reject_cancelled_type;
select set_config('tests.legacy_id', (select id::text from tests.legacy), true);

create function tests.legacy_id() returns uuid language sql stable as $f$ select id from tests.legacy $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  return v;
end $f$;
create function tests.cand(p_candidates jsonb, p_id uuid) returns jsonb language sql stable as $f$
  select item from jsonb_array_elements(coalesce(p_candidates -> 'opportunities', '[]'::jsonb)) item
   where (item ->> 'id')::uuid = p_id $f$;

select tests.mk_user('scope-u1');
select is(
  tests.cand(public.get_recommendation_candidates((select id from auth.users where email = 'scope-u1@tests.local')), tests.legacy_id()),
  null,
  'the candidate projection drops cancelled types even when their row is ACTIVE'
);

-- Discovery for a normal authenticated user must not expose the forced-ACTIVE legacy row.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', (select id from auth.users where email = 'scope-u1@tests.local'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is(
  (select count(*)::int from public.opportunities where id = current_setting('tests.legacy_id')::uuid),
  0,
  'RLS discovery hides cancelled types even when their row is ACTIVE'
);
reset role;

-- ---- 5. Applicant-facing tables are no longer part of the API ---------------------------------------
select is(has_table_privilege('authenticated', 'public.scholarship_applications', 'select'), false,
  'authenticated cannot read scholarship applications');
select is(has_table_privilege('authenticated', 'public.scholarship_application_status_history', 'select'), false,
  'authenticated cannot read scholarship application history');
select is(has_table_privilege('authenticated', 'public.competition_applications', 'select'), false,
  'authenticated cannot read competition applications');
select is(has_table_privilege('authenticated', 'public.competition_application_status_history', 'select'), false,
  'authenticated cannot read competition application history');
select is(has_table_privilege('service_role', 'public.scholarship_applications', 'select'), true,
  'service_role keeps read access for data retention');

-- ---- 6. Every scholarship/competition routine is closed to client roles ------------------------------
select is(has_function_privilege('authenticated', 'public.apply_for_scholarship(uuid,uuid,text,jsonb)', 'execute'), false,
  'apply_for_scholarship is revoked from authenticated');
select is(has_function_privilege('authenticated', 'public.withdraw_scholarship_application(uuid)', 'execute'), false,
  'withdraw_scholarship_application is revoked from authenticated');
select is(has_function_privilege('authenticated', 'public.apply_for_competition(uuid,uuid,text,jsonb)', 'execute'), false,
  'apply_for_competition is revoked from authenticated');
select is(has_function_privilege('authenticated', 'public.withdraw_competition_application(uuid)', 'execute'), false,
  'withdraw_competition_application is revoked from authenticated');
select is(has_function_privilege('authenticated', 'public.publish_admin_scholarship(uuid)', 'execute'), false,
  'the internal scholarship admin surface is revoked from authenticated');
select is(has_function_privilege('authenticated', 'public.process_scholarship_provider_event(text,text,text,text,text,text)', 'execute'), false,
  'the scholarship provider callback surface is revoked from authenticated');
select is(has_function_privilege('service_role', 'public.apply_for_scholarship(uuid,uuid,text,jsonb)', 'execute'), true,
  'service_role keeps execute for retention tooling');

select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','private')
      and (p.proname like '%scholarship%' or p.proname like '%competition%')
      and has_function_privilege('authenticated', p.oid, 'execute')),
  0,
  'no scholarship/competition routine is executable by authenticated'
);

-- ---- 7. The remaining catalogue still behaves normally -----------------------------------------------
select is(
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and public.is_opportunity_type_active(type)),
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and type not in ('SCHOLARSHIP','COMPETITION')),
  'the scope predicate excludes exactly the two cancelled types and nothing else'
);
select cmp_ok(
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and public.is_opportunity_type_active(type)),
  '>', 0,
  'the remaining catalogue still has discoverable listings'
);

select * from finish();
rollback;
