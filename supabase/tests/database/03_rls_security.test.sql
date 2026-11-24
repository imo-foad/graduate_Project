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
  perform tests.mk_user('u1'); perform tests.mk_user('u2');
  perform tests.mk_opp('o_open',   'JOB', '{"deadline_days":5}');
  perform tests.mk_opp('o_exp',    'JOB', '{"deadline_days":-1}');
  perform tests.mk_opp('o_closed', 'JOB', '{"deadline_days":5,"status":"CLOSED"}');
  perform tests.mk_opp('o_ended',  'EVENT', '{"start_days":-3,"end_days":-2}');
  perform tests.mk_opp('o_seen',   'JOB', '{"deadline_days":-2}');
  insert into public.skills (id, canonical_name, category) values ('T_GAP','T Gap','Test'), ('T_OLD','T Old','Test');
  insert into public.graduate_skills (graduate_id, skill_id, level, source) values (tests.id('u2'), 'T_GAP', 3, 'SEED');
  insert into public.applications (opportunity_id, graduate_id, status, status_source) values
    (tests.id('o_seen'), tests.id('u1'), 'SAMPLE_REJECTED', 'SEED_SAMPLE'),
    (tests.id('o_open'), tests.id('u2'), 'SAMPLE_INTERVIEW', 'SEED_SAMPLE');
  insert into public.notifications (profile_id, title, body, type) values (tests.id('u1'), 'n1', 'b', 't'), (tests.id('u2'), 'n2', 'b', 't');
  insert into public.recommendations (graduate_id, opportunity_id, score, band, missing_skill_ids, model_version)
  select tests.id('u1'), tests.id(k), 70, 'GOOD', case when k = 'o_open' then '["T_GAP"]'::jsonb else '["T_OLD"]'::jsonb end, 'test'
    from unnest(array['o_open','o_exp','o_closed','o_ended','o_seen']) k;
end $$;

select ok(not has_table_privilege('authenticated', 'public.opportunities', 'INSERT'), 'authenticated cannot INSERT opportunities');
select ok(not has_table_privilege('authenticated', 'public.opportunities', 'UPDATE'), 'authenticated cannot UPDATE opportunities');
select ok(not has_table_privilege('anon', 'public.opportunities', 'SELECT'), 'anon cannot SELECT opportunities');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 0, 'RLS enabled on every public table');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosecdef
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), 0, 'every SECURITY DEFINER function pins search_path');

-- isolation
select tests.login('u1');
select is((select count(*)::int from public.profiles), 1, 'u1 sees exactly one profile');
select is((select count(*)::int from public.graduate_profiles where profile_id = tests.id('u2')), 0, 'cannot read another graduate profile');
select is((select count(*)::int from public.graduate_skills where graduate_id = tests.id('u2')), 0, 'cannot read another graduate skills');
select is((select count(*)::int from public.applications where graduate_id = tests.id('u2')), 0, 'cannot read another graduate applications');
select is((select count(*)::int from public.notifications where profile_id = tests.id('u2')), 0, 'cannot read another graduate notifications');
select is((select count(*)::int from public.notifications), 1, 'sees only own notifications');

-- catalogue visibility (BR-005): open ones + ones already interacted with
select ok(exists (select 1 from public.opportunities where id = tests.id('o_open')), 'open opportunity visible');
select ok(not exists (select 1 from public.opportunities where id in (tests.id('o_exp'), tests.id('o_closed'), tests.id('o_ended'))), 'expired / closed / ended hidden');
select ok(exists (select 1 from public.opportunities where id = tests.id('o_seen')), 'expired opportunity still visible when the graduate already applied');

-- recommendation expiry (cached rows): only the open one survives, in every read path
select is((select count(*)::int from public.recommendations), 1, 'cached recommendations hide expired/closed/ended (table)');
select is((public.get_my_insights() -> 'recommendations' ->> 'count')::int, 1, 'insights ignore expired recommendations');
select is(jsonb_array_length(public.get_skill_gaps()), 1, 'skill gaps ignore expired recommendations');
select is(public.get_skill_gaps() -> 0 ->> 'skill_id', 'T_GAP', 'only the open recommendation contributes gaps');

-- writes that must be denied
select throws_ok($q$insert into public.opportunities (seed_key, type, title) values ('x','JOB','x')$q$, '42501', null, 'cannot insert opportunities');
select throws_ok($q$update public.opportunities set title = 'hacked'$q$, '42501', null, 'cannot update opportunities');
select throws_ok($q$delete from public.opportunities$q$, '42501', null, 'cannot delete opportunities');
select throws_ok($q$update public.profiles set account_status = 'SUSPENDED'$q$, '42501', null, 'cannot change account_status');
select throws_ok($q$update public.graduate_profiles set recommendations_dirty = false$q$, '42501', null, 'cannot touch server-managed columns');
select throws_ok($q$insert into public.applications (opportunity_id, graduate_id) values (tests.id('o_open'), tests.id('u1'))$q$, '42501', null, 'cannot insert applications directly');
select throws_ok($q$insert into public.event_registrations (opportunity_id, graduate_id, status) values (tests.id('o_open'), tests.id('u1'), 'REGISTERED')$q$, '42501', null, 'cannot insert registrations directly');
select throws_ok($q$insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values (tests.id('u1'), tests.id('o_open'), 100, 'HIGH', 'x')$q$, '42501', null, 'cannot forge recommendations');
select throws_ok($q$insert into public.notifications (profile_id, title, body, type) values (tests.id('u1'), 'a', 'b', 'c')$q$, '42501', null, 'cannot forge notifications');
select throws_ok($q$update public.notifications set title = 'x'$q$, '42501', null, 'only is_read is updatable');
select lives_ok($q$update public.notifications set is_read = true$q$, 'can mark own notifications read');
select throws_ok($q$insert into public.career_history (graduate_id, company_name, job_title, start_date, is_current) values (tests.id('u1'), 'c', 't', date '2020-01-01', true)$q$, '42501', null, 'cannot set is_current directly');
select throws_ok($q$delete from public.career_history$q$, '42501', null, 'career history cannot be deleted');
select lives_ok($q$insert into public.graduate_skills (graduate_id, skill_id, level) values (tests.id('u1'), 'T_GAP', 2)$q$, 'can add own MANUAL skill');
select throws_ok($q$insert into public.graduate_skills (graduate_id, skill_id, level, source) values (tests.id('u1'), 'T_OLD', 2, 'CV_CONFIRMED')$q$, '42501', null, 'cannot self-assign CV_CONFIRMED source');
select throws_ok($q$insert into public.graduate_skills (graduate_id, skill_id, level) values (tests.id('u2'), 'T_OLD', 2)$q$, '42501', null, 'cannot add skills to another graduate');
select lives_ok($q$update public.graduate_skills set level = 5 where graduate_id = tests.id('u2')$q$, 'updating another graduate skill is a silent no-op');
select lives_ok($q$update public.notifications set is_read = true where profile_id = tests.id('u2')$q$, 'updating another notification is a silent no-op');
select lives_ok($q$insert into public.saved_opportunities (graduate_id, opportunity_id) values (tests.id('u1'), tests.id('o_open'))$q$, 'can save an opportunity');
select throws_ok($q$insert into public.saved_opportunities (graduate_id, opportunity_id) values (tests.id('u2'), tests.id('o_open'))$q$, '42501', null, 'cannot save for another graduate');
select throws_ok($q$insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes) values (tests.id('u1'), tests.id('u2')::text || '/x.pdf', 'pdf', 10)$q$, '42501', null, 'cv row must point into own storage folder');
select lives_ok($q$insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes) values (tests.id('u1'), tests.id('u1')::text || '/x.pdf', 'pdf', 10)$q$, 'cv row inside own folder allowed');

reset role;
select is((select level from public.graduate_skills where graduate_id = tests.id('u2') and skill_id = 'T_GAP'), 3::smallint, 'u2 skill unchanged by u1');
select is((select is_read from public.notifications where profile_id = tests.id('u2')), false, 'u2 notification unchanged by u1');

-- internal / service-only functions are not callable by clients
select tests.login('u1');
select throws_ok($q$select public.get_recommendation_candidates(tests.id('u1'))$q$, '42501', null, 'candidates RPC is service-only');
select throws_ok($q$select public.save_recommendations(tests.id('u1'), '[]'::jsonb, 'x', 0)$q$, '42501', null, 'save_recommendations is service-only');
select throws_ok($q$select public.eligibility_failures(tests.id('u1'), tests.id('o_open'))$q$, '42501', null, 'eligibility_failures is service-only');
select throws_ok($q$select public._open_recommendations(tests.id('u1'))$q$, '42501', null, 'internal helper not callable');

-- service role path (what the Edge Function uses)
reset role;
select set_config('role', 'service_role', true);
select lives_ok($q$select public.get_recommendation_candidates(tests.id('u1'))$q$, 'service_role can fetch candidates');
select is((select count(*)::int from jsonb_array_elements(public.get_recommendation_candidates(tests.id('u1')) -> 'opportunities') o
            where (o ->> 'id')::uuid in (tests.id('o_exp'), tests.id('o_closed'), tests.id('o_ended'), tests.id('o_seen'))), 0, 'candidates exclude expired/closed/ended');
select lives_ok($q$select public.save_recommendations(tests.id('u1'), jsonb_build_array(jsonb_build_object('opportunity_id', tests.id('o_open'), 'score', 88, 'band', 'HIGH')), 'test', (select profile_version from public.graduate_profiles where profile_id = tests.id('u1')))$q$, 'service_role can save');
select throws_ok($q$select public.save_recommendations(tests.id('u1'), '[{"score":1}]'::jsonb, 'x', 0)$q$, 'PT422', 'INVALID_ITEMS', 'items without opportunity_id rejected');
reset role;
select is((select count(*)::int from public.recommendations where graduate_id = tests.id('u1')), 1, 'save_recommendations replaced the stale set');

-- anon
select set_config('role', 'anon', true);
select throws_ok($q$select count(*) from public.opportunities$q$, '42501', null, 'anon cannot read catalogue');
select throws_ok($q$select count(*) from public.skills$q$, '42501', null, 'anon cannot read skills');
select throws_ok($q$select public.apply_for_job(gen_random_uuid())$q$, '42501', null, 'anon cannot call RPCs');

reset role;
select * from finish();
rollback;
