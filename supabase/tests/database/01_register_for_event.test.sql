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
  -- Both waiters start eligible; u2's certification is revoked after queueing to test promotion skip.

  perform tests.mk_opp('e_cap',    'TRAINING', '{"capacity":2,"deadline_days":5}');
  perform tests.mk_opp('e_wait',   'TRAINING', '{"capacity":1,"waitlist":true,"deadline_days":5}');
  perform tests.mk_opp('e_nowait', 'TRAINING', '{"capacity":1,"deadline_days":5}');
  perform tests.mk_opp('e_closed', 'TRAINING', '{"deadline_days":-1}');
  perform tests.mk_opp('j_job',    'JOB',   '{"deadline_days":5}');
  perform tests.mk_opp('e_skip',   'TRAINING', '{"capacity":1,"waitlist":true,"deadline_days":5}');
  insert into public.opportunity_eligibility (opportunity_id, required_certifications)
    values (tests.id('e_skip'), array['Security+']);
  -- The seat holder and both queued candidates must be eligible at entry time.
  -- u2 loses the certification only after waitlisting, so the FIFO scan must skip u2 and promote u3.
  insert into public.certifications (graduate_id, title)
    values (tests.id('u1'), 'Security+'),
           (tests.id('u2'), 'Security+'),
           (tests.id('u3'), 'Security+');
end $$;

-- 1. NEW user, capacity available (regression for the FOUND bug: the row used to be never inserted)
select tests.login('u1');
select is((public.register_for_event(tests.id('e_cap'))).status, 'REGISTERED', 'new user with capacity -> REGISTERED');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_cap')), 1, 'registered_count = 1');
select is((select count(*)::int from public.event_registrations where opportunity_id = tests.id('e_cap') and graduate_id = tests.id('u1')), 1, 'exactly one registration row exists');
select is((select count(*)::int from public.notifications where profile_id = tests.id('u1') and type = 'TRAINING_REGISTERED'), 1, 'notification created');

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
select is((public.register_for_event(tests.id('e_wait'))).status, 'REGISTERED', 'waitlist training: first user REGISTERED');
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

-- A confirmed cancellation atomically promotes the oldest FIFO entry before a new user can claim the seat.
select tests.login('u1');
select is((public.cancel_event_registration(tests.id('e_wait'))).status, 'CANCELLED',
  'confirmed participant cancellation succeeds');
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('e_wait') and graduate_id = tests.id('u2')), 'REGISTERED',
  'the oldest eligible waitlisted participant is automatically promoted');
select is((select registered_count from public.opportunities where id = tests.id('e_wait')), 1,
  'FIFO promotion restores the confirmed registration counter');
select tests.login('u3');
select is((public.register_for_event(tests.id('e_wait'))).status, 'WAITLISTED',
  'a later new participant cannot steal the seat already promoted to FIFO');
select is((public.cancel_event_registration(tests.id('e_wait'))).status, 'CANCELLED',
  'a later waitlisted participant can cancel their queue entry');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_wait')), 1,
  'cancelling a WAITLISTED participant does not free the confirmed seat');
select is((select status from public.event_registrations
  where opportunity_id = tests.id('e_wait') and graduate_id = tests.id('u2')), 'REGISTERED',
  'the promoted FIFO participant keeps the confirmed seat');
select is((select count(*)::int
  from public.event_registration_status_history h
  join public.event_registrations r on r.id = h.registration_id
  where r.opportunity_id = tests.id('e_wait')
    and r.graduate_id = tests.id('u1')
    and h.old_status = 'REGISTERED' and h.new_status = 'CANCELLED'
    and h.actor_user_id = tests.id('u1') and h.source_type = 'CANDIDATE'),
  1, 'confirmed cancellation is recorded in candidate status history');
select is((select count(*)::int
  from public.event_registration_status_history h
  join public.event_registrations r on r.id = h.registration_id
  where r.opportunity_id = tests.id('e_wait')
    and r.graduate_id = tests.id('u2')
    and h.old_status = 'WAITLISTED' and h.new_status = 'REGISTERED'
    and h.actor_user_id is null and h.source_type = 'SYSTEM'),
  1, 'FIFO promotion is recorded separately as a system status-history event');
select is((select count(*)::int
  from public.notifications n
  join public.event_registrations r on r.id = n.related_entity_id
  where r.opportunity_id = tests.id('e_wait')
    and r.graduate_id = tests.id('u2')
    and n.profile_id = tests.id('u2')
    and n.type = 'TRAINING_WAITLIST_PROMOTED'),
  1, 'FIFO promotion sends the promoted participant a TRAINING_WAITLIST_PROMOTED notification');

-- A queued candidate whose eligibility is revoked is skipped; the next eligible FIFO candidate is promoted.
select tests.login('u1');
select is((public.register_for_event(tests.id('e_skip'))).status, 'REGISTERED',
  'eligibility-skip fixture fills its confirmed seat');
select tests.login('u2');
select is((public.register_for_event(tests.id('e_skip'))).status, 'WAITLISTED',
  'older candidate enters the waitlist while eligible');
select tests.login('u3');
select is((public.register_for_event(tests.id('e_skip'))).status, 'WAITLISTED',
  'later candidate also enters the waitlist while eligible');
reset role;
-- now() is transaction-stable in pgTAP; assign distinct registered_at values to model real FIFO arrivals.
update public.event_registrations
   set registered_at = case
     when graduate_id = tests.id('u2') then now() - interval '2 minutes'
     when graduate_id = tests.id('u3') then now() - interval '1 minute'
     else registered_at end
 where opportunity_id = tests.id('e_skip') and status = 'WAITLISTED';
delete from public.certifications
 where graduate_id = tests.id('u2') and lower(title) = 'security+';
select tests.login('u1');
select is((public.cancel_event_registration(tests.id('e_skip'))).status, 'CANCELLED',
  'confirmed cancellation starts the eligibility-aware FIFO promotion scan');
reset role;
select is((select status from public.event_registrations
  where opportunity_id = tests.id('e_skip') and graduate_id = tests.id('u2')), 'WAITLISTED',
  'the oldest ineligible candidate remains WAITLISTED and is skipped');
select is((select status from public.event_registrations
  where opportunity_id = tests.id('e_skip') and graduate_id = tests.id('u3')), 'REGISTERED',
  'the next eligible candidate is promoted after the ineligible waiter is skipped');
select is((select registered_count from public.opportunities where id = tests.id('e_skip')), 1,
  'eligibility-aware promotion preserves the confirmed seat counter');
select is((select count(*)::int from public.notifications n
  join public.event_registrations r on r.id = n.related_entity_id
  where r.opportunity_id = tests.id('e_skip') and r.graduate_id = tests.id('u3')
    and n.profile_id = tests.id('u3') and n.type = 'TRAINING_WAITLIST_PROMOTED'), 1,
  'only the promoted eligible candidate receives the promotion notification');
select is((select count(*)::int from public.event_registration_status_history h
  join public.event_registrations r on r.id = h.registration_id
  where r.opportunity_id = tests.id('e_skip') and r.graduate_id = tests.id('u2')
    and h.old_status = 'WAITLISTED' and h.new_status = 'REGISTERED'
    and h.source_type = 'SYSTEM'), 0,
  'the skipped ineligible candidate has no promotion history row');

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
          0, 'registered_count == count(REGISTERED) for every test training');

reset role;
select * from finish();
rollback;
