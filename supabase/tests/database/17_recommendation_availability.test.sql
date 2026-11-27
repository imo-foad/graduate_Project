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
-- One candidate projection item, looked up by test key (null when absent).
create function tests.cand(p_candidates jsonb, p_key text) returns jsonb language sql stable as $f$
  select item from jsonb_array_elements(coalesce(p_candidates -> 'opportunities', '[]'::jsonb)) item
   where (item ->> 'id')::uuid = tests.id(p_key) $f$;

do $$ begin
  perform tests.mk_user('u1');
  perform tests.mk_opp('e_open', 'TRAINING', '{"capacity":10,"deadline_days":5,"end_days":6}');
  perform tests.mk_opp('e_upcoming', 'TRAINING', '{"capacity":10,"deadline_days":5}');
  perform tests.mk_opp('e_wait', 'TRAINING', '{"capacity":1,"waitlist":true,"deadline_days":5}');
  perform tests.mk_opp('e_full', 'TRAINING', '{"capacity":1,"deadline_days":5}');
  perform tests.mk_opp('j_job', 'JOB', '{"deadline_days":5}');
  perform tests.mk_opp('e_closed', 'TRAINING', '{"capacity":5,"status":"CLOSED","deadline_days":5}');
end $$;

-- Availability state the projection must expose to the Edge Function.
reset role;
update public.opportunities set registration_opens_at = now() + interval '1 day' where id = tests.id('e_upcoming');
update public.opportunities set registered_count = 1 where id = tests.id('e_wait');
update public.opportunities set registered_count = 1 where id = tests.id('e_full');

create table tests.candidates as
  select public.get_recommendation_candidates(tests.id('u1')) as body;

select ok((tests.cand((select body from tests.candidates), 'e_open') ? 'status')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'deadline')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'end_at')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'registration_opens_at')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'capacity')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'registered_count')
       and (tests.cand((select body from tests.candidates), 'e_open') ? 'waitlist_enabled'),
       'candidate projection exposes lifecycle, registration window and capacity fields');

select is(tests.cand((select body from tests.candidates), 'e_open') ->> 'status', 'ACTIVE',
       'open opportunity status reaches the scorer');
select ok((tests.cand((select body from tests.candidates), 'e_open') ->> 'deadline')::timestamptz > now(),
       'open opportunity deadline reaches the scorer');
select ok((tests.cand((select body from tests.candidates), 'e_open') ->> 'end_at')::timestamptz > now(),
       'open opportunity end_at reaches the scorer');

select is((tests.cand((select body from tests.candidates), 'e_open') ->> 'capacity')::int, 10,
       'open training exposes its capacity');
select is((tests.cand((select body from tests.candidates), 'e_open') ->> 'registered_count')::int, 0,
       'open training exposes its registered count');
select is((tests.cand((select body from tests.candidates), 'e_open') ->> 'waitlist_enabled')::boolean, false,
       'open training exposes its waitlist flag');

select is(tests.cand((select body from tests.candidates), 'e_upcoming') ->> 'registration_opens_at' is not null, true,
       'upcoming registration window is exposed');
select is((tests.cand((select body from tests.candidates), 'e_upcoming') ->> 'registration_opens_at')::timestamptz > now(), true,
       'upcoming registration window is in the future');

select is((tests.cand((select body from tests.candidates), 'e_wait') ->> 'registered_count')::int,
       (tests.cand((select body from tests.candidates), 'e_wait') ->> 'capacity')::int,
       'waitlist training is at capacity and exposes the reached capacity');
select is((tests.cand((select body from tests.candidates), 'e_wait') ->> 'waitlist_enabled')::boolean, true,
       'waitlist training exposes waitlist_enabled = true');

select is((tests.cand((select body from tests.candidates), 'e_full') ->> 'registered_count')::int,
       (tests.cand((select body from tests.candidates), 'e_full') ->> 'capacity')::int,
       'full training is at capacity');
select is((tests.cand((select body from tests.candidates), 'e_full') ->> 'waitlist_enabled')::boolean, false,
       'full training has no waitlist, so the Edge Function must drop it');

select is(tests.cand((select body from tests.candidates), 'e_closed'), null,
       'closed opportunities never reach the recommendation projection');
select is(tests.cand((select body from tests.candidates), 'j_job') ->> 'capacity', null,
       'non-registrable opportunities carry no registration capacity');

-- Capacity and registration-window changes must invalidate cached rankings.
reset role;
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('u1');
update public.opportunities set registered_count = 2 where id = tests.id('e_open');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('u1')), true,
       'changing registered_count invalidates cached recommendations');

update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('u1');
update public.opportunities set capacity = 20 where id = tests.id('e_open');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('u1')), true,
       'changing capacity invalidates cached recommendations');

update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('u1');
update public.opportunities set registration_opens_at = now() - interval '1 hour' where id = tests.id('e_upcoming');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('u1')), true,
       'opening a registration window invalidates cached recommendations');

update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('u1');
update public.opportunities set waitlist_enabled = true where id = tests.id('e_full');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('u1')), true,
       'changing the waitlist flag invalidates cached recommendations');

-- Cancelling a registration frees a seat, and the projection reports it.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('u1'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is((public.register_for_event(tests.id('e_open'))).status, 'REGISTERED', 'registration takes a free seat');
select is((public.cancel_event_registration(tests.id('e_open'))).status, 'CANCELLED', 'cancellation releases the seat');
reset role;
select is((select registered_count from public.opportunities where id = tests.id('e_open')), 2,
       'cancellation restores the previous registered_count (no leak on this fixture)');

reset role;
select * from finish();
rollback;
