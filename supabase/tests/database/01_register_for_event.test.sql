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
  insert into public.opportunities (seed_key, type, title, status, deadline, start_at, end_at, capacity, waitlist_enabled, attendance_mode)
  values ('t-' || p_key, p_type, 'Test ' || p_key, coalesce(p_props ->> 'status', 'ACTIVE'),
    case when p_props ? 'deadline_days' then now() + make_interval(days => (p_props ->> 'deadline_days')::int) end,
    case when p_props ? 'start_days' then now() + make_interval(days => (p_props ->> 'start_days')::int) end,
    case when p_props ? 'end_days' then now() + make_interval(days => (p_props ->> 'end_days')::int) end,
    (p_props ->> 'capacity')::int, coalesce((p_props ->> 'waitlist')::boolean, false), 'ONLINE')
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
-- Impersonate a user exactly as PostgREST does: JWT claims + role. Use `reset role;` to go back to postgres.
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

do $$ begin
  perform tests.mk_user('u1'); perform tests.mk_user('u2'); perform tests.mk_user('u3');
  perform tests.mk_opp('e_cap',    'EVENT', '{"capacity":2,"deadline_days":5}');
  perform tests.mk_opp('e_wait',   'EVENT', '{"capacity":1,"waitlist":true,"deadline_days":5}');
  perform tests.mk_opp('e_nowait', 'EVENT', '{"capacity":1,"deadline_days":5}');
  perform tests.mk_opp('e_closed', 'EVENT', '{"deadline_days":-1}');
  perform tests.mk_opp('j_job',    'JOB',   '{"deadline_days":5}');
end $$;

-- 1. NEW user, capacity available (regression for the FOUND bug: the row used to be never inserted)
select tests.login('u1');
select is((public.register_for_event(tests.id('e_cap'))).status, 'REGISTERED', 'new user with capacity -> REGISTERED');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_cap')), 1, 'registered_count = 1');
select is((select count(*)::int from public.event_registrations where opportunity_id = tests.id('e_cap') and graduate_id = tests.id('u1')), 1, 'exactly one registration row exists');
select is((select count(*)::int from public.notifications where profile_id = tests.id('u1') and type = 'EVENT_REGISTERED'), 1, 'notification created');

-- duplicate
select tests.login('u1');
select throws_ok($q$select public.register_for_event(tests.id('e_cap'))$q$, 'PT409', 'ALREADY_REGISTERED', 'duplicate registration rejected');

-- fill the last seat, then full + NO waitlist
select tests.login('u2');
select is((public.register_for_event(tests.id('e_cap'))).status, 'REGISTERED', 'second user takes the last seat');
select tests.login('u3');
select throws_ok($q$select public.register_for_event(tests.id('e_cap'))$q$, 'PT409', 'EVENT_FULL', 'full + no waitlist -> EVENT_FULL');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_cap')), 2, 'count did not exceed capacity');
select is((select count(*)::int from public.event_registrations where opportunity_id = tests.id('e_cap') and graduate_id = tests.id('u3')), 0, 'no row created for rejected user');

-- 2. full + waitlist ENABLED
select tests.login('u1');
select is((public.register_for_event(tests.id('e_wait'))).status, 'REGISTERED', 'waitlist event: first user REGISTERED');
select tests.login('u2');
select is((public.register_for_event(tests.id('e_wait'))).status, 'WAITLISTED', 'full + waitlist -> WAITLISTED');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_wait')), 1, 'waitlisting does not change registered_count');

-- 3. cancel: REGISTERED decrements, WAITLISTED does not, double cancel rejected
select tests.login('u1');
select is((public.cancel_event_registration(tests.id('e_cap'))).status, 'CANCELLED', 'cancel REGISTERED');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_cap')), 1, 'registered_count decremented 2 -> 1');
select tests.login('u1');
select throws_ok($q$select public.cancel_event_registration(tests.id('e_cap'))$q$, 'PT409', 'ALREADY_CANCELLED', 'second cancel rejected');
select tests.login('u2');
select is((public.cancel_event_registration(tests.id('e_wait'))).status, 'CANCELLED', 'cancel WAITLISTED');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_wait')), 1, 'cancelling a waitlisted user does not decrement');

-- 4. re-register after cancel: capacity available -> REGISTERED on the SAME row
select tests.login('u1');
select is((public.register_for_event(tests.id('e_cap'))).status, 'REGISTERED', 're-register after cancel (capacity free)');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_cap')), 2, 'registered_count back to 2');
select is((select count(*)::int from public.event_registrations where opportunity_id = tests.id('e_cap') and graduate_id = tests.id('u1')), 1, 'row reused, not duplicated');

-- re-register after cancel while full + waitlist -> WAITLISTED
select tests.login('u2');
select is((public.register_for_event(tests.id('e_wait'))).status, 'WAITLISTED', 're-register after cancel (full + waitlist)');
reset role;
select is((select count(*)::int from public.event_registrations where opportunity_id = tests.id('e_wait') and graduate_id = tests.id('u2')), 1, 'single row for re-registered user');

-- freeing a seat lets a NEW user register (no auto-promotion is specified in the source)
select tests.login('u1');
select public.cancel_event_registration(tests.id('e_wait'));
select tests.login('u3');
select is((public.register_for_event(tests.id('e_wait'))).status, 'REGISTERED', 'seat freed by cancellation can be taken');

-- 5. rule violations
select tests.login('u1');
select throws_ok($q$select public.register_for_event(tests.id('e_closed'))$q$, 'PT422', 'REGISTRATION_CLOSED', 'past deadline');
select throws_ok($q$select public.register_for_event(tests.id('j_job'))$q$, 'PT422', 'NOT_REGISTRABLE', 'JOB is not registrable');
select throws_ok($q$select public.register_for_event(gen_random_uuid())$q$, 'PT404', 'OPPORTUNITY_NOT_FOUND', 'unknown id');
select set_config('request.jwt.claims', '', true);
select throws_ok($q$select public.register_for_event(tests.id('e_cap'))$q$, 'PT401', 'UNAUTHENTICATED', 'no JWT subject');

-- 6. denormalised counter always equals the number of REGISTERED rows
reset role;
select is((select count(*)::int from public.opportunities o where o.seed_key like 't-%'
            and o.registered_count <> (select count(*) from public.event_registrations r where r.opportunity_id = o.id and r.status = 'REGISTERED')),
          0, 'registered_count == count(REGISTERED) for every test event');

reset role;
select * from finish();
rollback;
