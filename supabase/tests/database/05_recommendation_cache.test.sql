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

create table tests.vals (k text primary key, v bigint);
grant select on tests.vals to service_role, authenticated;
create function tests.ver(p_key text) returns bigint language sql stable as $f$
  select profile_version from public.graduate_profiles where profile_id = tests.id(p_key) $f$;
create function tests.item(p_opp text, p_score numeric, p_extra jsonb default '{}') returns jsonb language sql as $f$
  select jsonb_build_object('opportunity_id', tests.id(p_opp), 'score', p_score,
    'band', case when p_score >= 80 then 'HIGH' when p_score >= 65 then 'GOOD' when p_score >= 50 then 'MEDIUM' else 'LOW' end) || p_extra $f$;

do $$ begin
  perform tests.mk_user('r1'); perform tests.mk_user('r2');
  perform tests.mk_opp('o1', 'JOB', '{"deadline_days":5}');
  perform tests.mk_opp('o2', 'JOB', '{"deadline_days":5}');
  perform tests.mk_opp('o_exp', 'JOB', '{"deadline_days":-1}');
  perform tests.mk_opp('o_closed', 'JOB', '{"deadline_days":5,"status":"CLOSED"}');
  insert into public.skills (id, canonical_name, category) values ('T_SK_X', 'T Skill X', 'Test');
  insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values
    (tests.id('r1'), tests.id('o1'), 70, 'GOOD', 'seed'), (tests.id('r1'), tests.id('o2'), 55, 'MEDIUM', 'seed'),
    (tests.id('r2'), tests.id('o1'), 60, 'MEDIUM', 'seed');
end $$;
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'precondition: cache is dirty');

-- ===== Issue 1: invalid payloads are rejected BEFORE anything is deleted =====
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), null, 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'NULL payload rejected (not treated as an empty array)');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), '{"a":1}'::jsonb, 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'JSON object instead of array');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), '[1]'::jsonb, 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'array element that is not an object');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(jsonb_build_object('score', 50, 'band', 'MEDIUM')), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'missing opportunity_id');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || '{"opportunity_id":"not-a-uuid"}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'invalid UUID syntax (controlled error, not 22P02)');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || jsonb_build_object('opportunity_id', gen_random_uuid())), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'valid UUID but nonexistent opportunity');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 90), tests.item('o2', 80) || jsonb_build_object('opportunity_id', gen_random_uuid())), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'one bad item rejects the whole payload');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 101)), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'score above 100');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', -1)), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'negative score');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || '{"score":"60"}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'score as string');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(jsonb_build_object('opportunity_id', tests.id('o1'), 'band', 'LOW')), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'missing score');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 90) || '{"band":"LOW"}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'band inconsistent with score');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 90) || '{"band":"WOW"}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'unknown band');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || '{"reasons":"x"}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'reasons must be an array');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || '{"score_breakdown":[]}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'score_breakdown must be an object');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60) || '{"missing_skill_ids":[1]}'), 'test', tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'skill ids must be strings');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), '[]'::jsonb, null, tests.ver('r1'))$q$, 'PT422', 'INVALID_ITEMS', 'NULL model_version');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), '[]'::jsonb, 'test', null)$q$, 'PT422', 'INVALID_ITEMS', 'NULL profile version');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o_exp', 70)), 'test', tests.ver('r1'))$q$, 'PT409', 'OPPORTUNITY_UNAVAILABLE', 'expired opportunity cannot be saved');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o_closed', 70)), 'test', tests.ver('r1'))$q$, 'PT409', 'OPPORTUNITY_UNAVAILABLE', 'closed opportunity cannot be saved');
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 70), tests.item('o_exp', 70)), 'test', tests.ver('r1'))$q$, 'PT409', 'OPPORTUNITY_UNAVAILABLE', 'open + expired mix rejects everything');
select throws_ok($q$select public.save_recommendations(gen_random_uuid(), '[]'::jsonb, 'test', 0)$q$, 'PT404', 'GRADUATE_NOT_FOUND', 'unknown graduate');

reset role;
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 2, 'after 22 rejected calls the cache still has both rows');
select is((select array_agg(score order by score) from public.recommendations where graduate_id = tests.id('r1')), array[55.00, 70.00]::numeric[], 'cached scores untouched');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'recommendations_dirty NOT cleared by rejected payloads');

-- valid payload; the other graduate is unaffected
select set_config('role', 'service_role', true);
select is(public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 88, '{"reasons":["r"],"matched_skill_ids":["A"],"missing_skill_ids":["B"],"explanation_ar":"x"}')), 'test', tests.ver('r1')), 1, 'valid payload stored');
reset role;
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 1, 'rows not in the payload are removed');
select is((select score from public.recommendations where graduate_id = tests.id('r1') and opportunity_id = tests.id('o1')), 88.00, 'score updated');
select is((select model_version from public.recommendations where graduate_id = tests.id('r1')), 'test', 'model_version recorded');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), false, 'dirty cleared after a valid save');
select is((select score from public.recommendations where graduate_id = tests.id('r2')), 60.00, 'other graduate cache untouched');

-- duplicate opportunity ids: highest score wins, then first in payload
select set_config('role', 'service_role', true);
select is(public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 80, '{"explanation_ar":"first"}'), tests.item('o1', 80, '{"explanation_ar":"second"}'), tests.item('o1', 70, '{"explanation_ar":"third"}')), 'test', tests.ver('r1')), 1, 'duplicates collapse to one row');
reset role;
select is((select explanation_ar from public.recommendations where graduate_id = tests.id('r1')), 'first', 'tie on score -> first in payload wins');
select set_config('role', 'service_role', true);
select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 60, '{"explanation_ar":"low"}'), tests.item('o1', 90, '{"explanation_ar":"high"}')), 'test', tests.ver('r1'));
reset role;
select is((select explanation_ar from public.recommendations where graduate_id = tests.id('r1')), 'high', 'highest score wins among duplicates');

-- empty array = "nothing eligible for this snapshot": clears the cache and marks it fresh
select set_config('role', 'service_role', true);
select is(public.save_recommendations(tests.id('r1'), '[]'::jsonb, 'test', tests.ver('r1')), 0, 'empty array is valid and stores nothing');
reset role;
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 0, 'empty array clears this graduate cache');
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r2')), 1, 'and only this graduate cache');

-- ===== Issue 2: profile_version semantics =====
insert into tests.vals values ('v', tests.ver('r1'));
update public.graduate_profiles set recommendations_dirty = true where profile_id = tests.id('r1');
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v'), 'flipping recommendations_dirty does NOT change profile_version');
update public.graduate_profiles set major = major where profile_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v'), 'no-op update does not bump');
update public.graduate_profiles set employment_status = 'SEEKING' where profile_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v'), 'employment_status is not a scoring input -> no bump');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), false, '... and does not dirty the cache');

insert into public.graduate_skills (graduate_id, skill_id, level) values (tests.id('r1'), 'T_SK_X', 2);
select is(tests.ver('r1'), (select v from tests.vals where k = 'v') + 1, 'skill insert bumps version');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'skill insert dirties cache');
update public.graduate_skills set level = 3 where graduate_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v') + 2, 'skill update bumps version');
delete from public.graduate_skills where graduate_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v') + 3, 'skill delete bumps version');
update public.graduate_profiles set major = 'Physics' where profile_id = tests.id('r1');
select is(tests.ver('r1'), (select v from tests.vals where k = 'v') + 4, 'profile field change bumps version');
select tests.login('r1');
update public.graduate_profiles set location = 'Cairo';
select throws_ok($q$update public.graduate_profiles set profile_version = 0$q$, '42501', null, 'clients cannot write profile_version');
select throws_ok($q$update public.graduate_profiles set recommendations_dirty = false$q$, '42501', null, 'clients cannot clear the cache flag');
reset role;
select is(tests.ver('r1'), (select v from tests.vals where k = 'v') + 5, 'client-side profile edit bumps version');

select set_config('role', 'service_role', true);
select is((public.get_recommendation_candidates(tests.id('r1')) ->> 'profile_version')::bigint, tests.ver('r1'), 'candidates RPC returns the current profile_version');
reset role;

-- stale snapshot after a skills change
delete from public.recommendations where graduate_id = tests.id('r1');
insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values (tests.id('r1'), tests.id('o1'), 66, 'GOOD', 'known');
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('r1');
insert into tests.vals values ('snap', tests.ver('r1')) on conflict (k) do update set v = excluded.v;
insert into public.graduate_skills (graduate_id, skill_id, level) values (tests.id('r1'), 'T_SK_X', 4);
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 99)), 'test', (select v from tests.vals where k = 'snap'))$q$, 'PT409', 'STALE_SNAPSHOT', 'old snapshot rejected after skills change');
reset role;
select is((select model_version from public.recommendations where graduate_id = tests.id('r1')), 'known', 'old recommendations preserved after skills change');
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 1, 'nothing deleted after skills change');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'dirty stays true after skills change');

-- stale snapshot after a profile change
delete from public.recommendations where graduate_id = tests.id('r1');
insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values (tests.id('r1'), tests.id('o1'), 66, 'GOOD', 'known');
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('r1');
insert into tests.vals values ('snap', tests.ver('r1')) on conflict (k) do update set v = excluded.v;
update public.graduate_profiles set department = 'Changed dept' where profile_id = tests.id('r1');
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 99)), 'test', (select v from tests.vals where k = 'snap'))$q$, 'PT409', 'STALE_SNAPSHOT', 'old snapshot rejected after profile change');
reset role;
select is((select model_version from public.recommendations where graduate_id = tests.id('r1')), 'known', 'old recommendations preserved after profile change');
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 1, 'nothing deleted after profile change');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'dirty stays true after profile change');

-- stale snapshot after a experience change
delete from public.recommendations where graduate_id = tests.id('r1');
insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values (tests.id('r1'), tests.id('o1'), 66, 'GOOD', 'known');
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('r1');
insert into tests.vals values ('snap', tests.ver('r1')) on conflict (k) do update set v = excluded.v;
insert into public.career_history (graduate_id, company_name, job_title, start_date, end_date) values (tests.id('r1'), 'Co', 'T', date '2020-01-01', date '2021-01-01');
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 99)), 'test', (select v from tests.vals where k = 'snap'))$q$, 'PT409', 'STALE_SNAPSHOT', 'old snapshot rejected after experience change');
reset role;
select is((select model_version from public.recommendations where graduate_id = tests.id('r1')), 'known', 'old recommendations preserved after experience change');
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 1, 'nothing deleted after experience change');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'dirty stays true after experience change');

-- stale snapshot after a certification change
delete from public.recommendations where graduate_id = tests.id('r1');
insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values (tests.id('r1'), tests.id('o1'), 66, 'GOOD', 'known');
update public.graduate_profiles set recommendations_dirty = false where profile_id = tests.id('r1');
insert into tests.vals values ('snap', tests.ver('r1')) on conflict (k) do update set v = excluded.v;
insert into public.certifications (graduate_id, title) values (tests.id('r1'), 'Cert');
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 99)), 'test', (select v from tests.vals where k = 'snap'))$q$, 'PT409', 'STALE_SNAPSHOT', 'old snapshot rejected after certification change');
reset role;
select is((select model_version from public.recommendations where graduate_id = tests.id('r1')), 'known', 'old recommendations preserved after certification change');
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('r1')), 1, 'nothing deleted after certification change');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), true, 'dirty stays true after certification change');

-- retry with a fresh snapshot succeeds and only then marks the cache fresh
select set_config('role', 'service_role', true);
select is(public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 77)), 'test', (public.get_recommendation_candidates(tests.id('r1')) ->> 'profile_version')::bigint), 1, 'fresh snapshot accepted');
reset role;
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), false, 'fresh after matching save');
select is((select score from public.recommendations where graduate_id = tests.id('r1')), 77.00, 'new cache content stored');
-- an OLDER snapshot can no longer overwrite newer data
select set_config('role', 'service_role', true);
select throws_ok($q$select public.save_recommendations(tests.id('r1'), jsonb_build_array(tests.item('o1', 11)), 'test', (select v from tests.vals where k = 'snap'))$q$, 'PT409', 'STALE_SNAPSHOT', 'replaying the old snapshot is rejected');
reset role;
select is((select score from public.recommendations where graduate_id = tests.id('r1')), 77.00, 'newer cache not overwritten by the older calculation');
select is((select recommendations_dirty from public.graduate_profiles where profile_id = tests.id('r1')), false, 'rejected replay does not alter the flag');

reset role;
select * from finish();
rollback;
