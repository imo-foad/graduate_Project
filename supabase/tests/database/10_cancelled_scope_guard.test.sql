-- 0025/0026 scope guard: the active catalogue is exactly JOB, INTERNSHIP and TRAINING. Scholarship (#14),
-- Competition (#15), EVENT, CONFERENCE and VOLUNTEER are inactive; historical rows are retained but must
-- never be exposed as actionable. These tests prove the database enforces that, and that retained history
-- did not have to be deleted.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

-- ---- 1. The single scope predicate -----------------------------------------------------------------
select is(public.is_opportunity_type_active('JOB'), true, 'JOB is in the active product scope');
select is(public.is_opportunity_type_active('INTERNSHIP'), true, 'INTERNSHIP is in the active product scope');
select is(public.is_opportunity_type_active('TRAINING'), true, 'TRAINING is in the active product scope');
select is(public.is_opportunity_type_active('EVENT'), false, 'EVENT is not an independent active type');
select is(public.is_opportunity_type_active('CONFERENCE'), false, 'CONFERENCE is not an independent active type');
select is(public.is_opportunity_type_active('VOLUNTEER'), false, 'VOLUNTEER is not an independent active type');
select is(public.is_opportunity_type_active('SCHOLARSHIP'), false, 'SCHOLARSHIP is cancelled');
select is(public.is_opportunity_type_active('COMPETITION'), false, 'COMPETITION is cancelled');
select is(public.is_opportunity_type_active(null), false, 'a null type is never active');
select is(public.is_opportunity_type_active('SOMETHING_NEW'), false, 'unknown types are not active');
select is(public.is_opportunity_type_active(''), false, 'an empty type is not active');
select is(public.is_opportunity_type_active('   '), false, 'a whitespace-only type is not active');
-- Parity contract mirrored in TypeScript (_shared/opportunity-state.ts) and OpenAPI: matching is
-- case-sensitive and exact, so these must stay rejected.
select is(public.is_opportunity_type_active('job'), false, 'type matching is case-sensitive (lowercase job)');
select is(public.is_opportunity_type_active('Job'), false, 'type matching is case-sensitive (mixed-case Job)');
select is(public.is_opportunity_type_active('JOB '), false, 'types are not trimmed (trailing space)');
select is(public.is_opportunity_type_active(' JOB'), false, 'types are not trimmed (leading space)');
select is(public.is_opportunity_type_active('JOBS'), false, 'near-miss values are not active');
select is(public.is_opportunity_type_active('TRAININGS'), false, 'near-miss TRAININGS is not active');

-- ---- 2. Seed data ships only the three approved types -----------------------------------------------
select is(
  (select count(*)::int from public.opportunities where type not in ('JOB','INTERNSHIP','TRAINING')),
  0,
  'the seeded catalogue contains no inactive opportunity type'
);
select is(
  (select count(*)::int from public.opportunities where type = 'TRAINING' and status = 'ACTIVE'),
  (select count(*)::int from public.opportunities where type = 'TRAINING' and public.is_opportunity_open(status, deadline, end_at)),
  'active TRAINING rows remain discoverable'
);

-- ---- 3. No role may create a new excluded-type listing ----------------------------------------------
select throws_ok(
  $$ insert into public.opportunities (seed_key, type, title, status)
     values ('t-scope-new-event', 'EVENT', 'New event', 'ACTIVE') $$,
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'creating an EVENT opportunity is rejected'
);
select throws_ok(
  $$ insert into public.opportunities (seed_key, type, title, status)
     values ('t-scope-new-conference', 'CONFERENCE', 'New conference', 'CANCELLED') $$,
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'creating an excluded type is rejected even when the row is created as CANCELLED'
);
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
select throws_ok(
  $$ insert into public.opportunities (seed_key, type, title, status)
     values ('t-scope-new-volunteer', 'VOLUNTEER', 'New volunteer role', 'ACTIVE') $$,
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'creating a VOLUNTEER opportunity is rejected'
);

-- ---- 4. Retained history stays retained but not actionable -------------------------------------------
-- Reproduces pre-0026 data that this migration has to neutralise. The guard trigger is disabled only
-- inside this transaction to emulate a row that predates it.
alter table public.opportunities disable trigger opportunities_reject_cancelled_type;
create table tests.legacy (id uuid primary key);
with ins as (
  insert into public.opportunities (seed_key, type, title, status, deadline, capacity, waitlist_enabled, attendance_mode)
  values ('t-scope-legacy-event', 'EVENT', 'Legacy event', 'ACTIVE',
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
  'the candidate projection drops an EVENT row even when it was forced ACTIVE'
);

-- Discovery for a normal authenticated user must not expose the forced-ACTIVE legacy row.
select set_config('request.jwt.claims',
  jsonb_build_object('sub', (select id from auth.users where email = 'scope-u1@tests.local'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is(
  (select count(*)::int from public.opportunities where id = current_setting('tests.legacy_id')::uuid),
  0,
  'RLS discovery hides an EVENT even when its row is ACTIVE'
);
reset role;

-- A deactivated legacy row can never be reactivated by the service role either.
select throws_ok(
  format($$ update public.opportunities set status = 'ACTIVE' where id = %L $$, tests.legacy_id()),
  'PT422', 'CANCELLED_OPPORTUNITY_TYPE',
  'reactivating a retained excluded-type row is rejected'
);
-- ...but the one-way deactivation write is allowed, which is how legacy data was neutralised.
select lives_ok(
  format($$ update public.opportunities set status = 'CANCELLED' where id = %L $$, tests.legacy_id()),
  'deactivating a retained excluded-type row is allowed'
);

-- ---- 5. Applicant-facing cancelled tables are no longer part of the API ------------------------------
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

-- ---- 7. The three active types still behave normally ------------------------------------------------
select is(
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and public.is_opportunity_type_active(type)),
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and type in ('JOB','INTERNSHIP','TRAINING')),
  'the scope predicate accepts exactly the three active types and nothing else'
);
select cmp_ok(
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and public.is_opportunity_type_active(type)),
  '>', 0,
  'the active catalogue still has discoverable listings'
);
select is(
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and type in ('TRAINING')),
  (select count(*)::int from public.opportunities
    where public.is_opportunity_open(status, deadline, end_at)
      and public.is_opportunity_type_active(type) and type = 'TRAINING'),
  'TRAINING remains part of the discoverable active catalogue'
);

select * from finish();
rollback;
