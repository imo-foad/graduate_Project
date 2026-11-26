-- 0026: the active scope is JOB/INTERNSHIP/TRAINING. This file covers the parts that are not already
-- covered by 10_cancelled_scope_guard: TRAINING participates in recommendations and is the only
-- direct-registration type, while JOB/INTERNSHIP cannot be registered as training.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.mk_opp(p_key text, p_type text, p_props jsonb default '{}') returns uuid language plpgsql as $f$
declare v uuid;
begin
  -- Test-created rows must not be counted as synthetic catalogue seed rows.
  insert into public.opportunities (seed_key, type, title, status, deadline, capacity, waitlist_enabled,
    registration_opens_at, attendance_mode, is_sample)
  values ('t-' || p_key, p_type, 'Test ' || p_key, coalesce(p_props ->> 'status', 'ACTIVE'),
    now() + make_interval(days => coalesce((p_props ->> 'deadline_days')::int, 5)),
    (p_props ->> 'capacity')::int, coalesce((p_props ->> 'waitlist')::boolean, false),
    case when p_props ? 'opens_in_days' then now() + make_interval(days => (p_props ->> 'opens_in_days')::int) end,
    'ONLINE', false)
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end $f$;

-- pgTAP's throws_ok executes in a subtransaction; set the PostgREST-style claims inside the same
-- statement string so an expected error is asserted against the intended identity, not an empty JWT.
create function tests.as_user(p_uid uuid, p_sql text) returns text language sql immutable as $f$
  select format('select set_config(%L, %L, true); select set_config(%L, %L, true); ',
                'request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated')::text,
                'role', 'authenticated') || p_sql
$f$;

create function tests.cand(p_candidates jsonb, p_key text) returns jsonb language sql stable as $f$
  select item from jsonb_array_elements(coalesce(p_candidates -> 'opportunities', '[]'::jsonb)) item
   where (item ->> 'id')::uuid = tests.id(p_key) $f$;

select tests.mk_user('u1');
select tests.mk_opp('t_open', 'TRAINING', '{"capacity":5}');
select tests.mk_opp('t_upcoming', 'TRAINING', '{"capacity":5,"opens_in_days":2}');
select tests.mk_opp('t_full', 'TRAINING', '{"capacity":1}');
select tests.mk_opp('j_job', 'JOB', '{}');
select tests.mk_opp('j_internship', 'INTERNSHIP', '{}');
select tests.mk_opp('t_closed', 'TRAINING', '{"status":"CLOSED","capacity":5}');
update public.opportunities set registered_count = 1 where id = tests.id('t_full');

-- ---- Recommendation candidates include TRAINING with availability data ------------------------------
create table tests.candidates as select public.get_recommendation_candidates(tests.id('u1')) as body;
select is(tests.cand((select body from tests.candidates), 't_open') ->> 'type', 'TRAINING',
  'TRAINING is an active recommendation candidate');
select is((tests.cand((select body from tests.candidates), 't_open') ->> 'capacity')::int, 5,
  'the TRAINING candidate exposes capacity');
select is((tests.cand((select body from tests.candidates), 't_open') ->> 'registered_count')::int, 0,
  'the TRAINING candidate exposes registered_count');
select is(tests.cand((select body from tests.candidates), 't_full') ->> 'registered_count',
  tests.cand((select body from tests.candidates), 't_full') ->> 'capacity',
  'a full TRAINING candidate reports that capacity was reached');
select is(tests.cand((select body from tests.candidates), 't_closed'), null,
  'a CLOSED TRAINING is never a recommendation candidate');
select is(tests.cand((select body from tests.candidates), 'j_job') ->> 'type', 'JOB',
  'JOB remains an active candidate');
select is(tests.cand((select body from tests.candidates), 'j_internship') ->> 'type', 'INTERNSHIP',
  'INTERNSHIP remains an active candidate');

-- ---- Direct registration is TRAINING-only -----------------------------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('u1'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is((public.register_for_event(tests.id('t_open'))).status, 'REGISTERED',
  'a graduate registers directly for an open TRAINING');
select is((select registered_count from public.opportunities where id = tests.id('t_open')), 1,
  'training registration increments the authoritative counter');
select throws_ok(
  tests.as_user(tests.id('u1'), format('select public.register_for_event(%L)', tests.id('t_full'))),
  'PT409', 'EVENT_FULL',
  'a full TRAINING without a waitlist rejects registration'
);
select throws_ok(
  tests.as_user(tests.id('u1'), format('select public.register_for_event(%L)', tests.id('j_job'))),
  'PT422', 'NOT_REGISTRABLE',
  'JOB cannot be registered through the training registration path'
);
select throws_ok(
  tests.as_user(tests.id('u1'), format('select public.register_for_event(%L)', tests.id('j_internship'))),
  'PT422', 'NOT_REGISTRABLE',
  'INTERNSHIP cannot be registered through the training registration path'
);
select throws_ok(
  tests.as_user(tests.id('u1'), format('select public.register_for_event(%L)', tests.id('t_upcoming'))),
  'PT422', 'REGISTRATION_CLOSED',
  'TRAINING registration is rejected before the window opens'
);
select is((public.cancel_event_registration(tests.id('t_open'))).status, 'CANCELLED',
  'the participant can cancel a training registration');
reset role;

-- ---- Only the three active types survive the catalogue ----------------------------------------------
select is(
  (select count(*)::int from public.opportunities
    where type not in ('JOB','INTERNSHIP','TRAINING') and status <> 'CANCELLED'),
  0,
  'no non-cancelled row exists outside the three active types'
);
-- The fixture currently contains eight seeded TRAINING catalogue rows, including the DevOps
-- Cloud Day added for the career-cohort scenario. This test contributes four isolated TRAINING
-- fixtures (including one CLOSED row): keep the total at twelve while measuring seed rows independently.
select is(
  (select count(*)::int from public.opportunities where type = 'TRAINING'),
  12,
  'eight seeded TRAINING rows plus four test-owned TRAINING fixtures remain present'
);
select is(
  (select count(*)::int from public.opportunities where type = 'TRAINING' and is_sample is true),
  8,
  'the eight seeded TRAINING catalogue rows retain the sample-data marker'
);
-- Seed rows are marked is_sample=true by build-seed.mjs. Test-only fixtures above are
-- deliberately excluded because t_closed is a valid CLOSED TRAINING used by this test.
select is(
  (select count(*)::int from public.opportunities
    where type = 'TRAINING' and is_sample is true and status = 'ACTIVE'),
  (select count(*)::int from public.opportunities
    where type = 'TRAINING' and is_sample is true),
  'all seeded TRAINING catalogue rows stay active (they are part of the approved scope)'
);

select * from finish();
rollback;
