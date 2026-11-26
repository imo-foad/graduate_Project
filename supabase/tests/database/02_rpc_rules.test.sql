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
  perform tests.mk_user('a1'); perform tests.mk_user('a2');
  perform tests.mk_opp('j_ok',     'JOB',   '{"deadline_days":5}');
  perform tests.mk_opp('j_exp',    'JOB',   '{"deadline_days":-1}');
  perform tests.mk_opp('j_closed', 'JOB',   '{"deadline_days":5,"status":"CLOSED"}');
  perform tests.mk_opp('j_cert',   'JOB',   '{"deadline_days":5}');
  perform tests.mk_opp('j_sample', 'JOB',   '{"deadline_days":5}');
  perform tests.mk_opp('t_training', 'TRAINING', '{"deadline_days":5}');
  insert into public.opportunity_eligibility (opportunity_id, required_certifications) values (tests.id('j_cert'), array['Security+']);
  insert into public.skills (id, canonical_name, category) values ('T_SKILL_A','T Skill A','Test'), ('T_SKILL_B','T Skill B','Test');
  insert into public.cv_documents (id, graduate_id, storage_path, file_type, size_bytes)
    values ('00000000-0000-0000-0000-0000000000c2', tests.id('a2'), tests.id('a2')::text || '/cv.pdf', 'pdf', 1000);
  insert into public.applications (id, opportunity_id, graduate_id, status, status_source)
    values ('00000000-0000-0000-0000-0000000000d2', tests.id('j_sample'), tests.id('a2'), 'SAMPLE_INTERVIEW', 'SEED_SAMPLE');
end $$;

-- apply_for_job
select tests.login('a1');
select is((public.apply_for_job(tests.id('j_ok'))).status, 'SUBMITTED', 'apply -> SUBMITTED');
reset role;
select is((select status_source from public.applications where graduate_id = tests.id('a1') and opportunity_id = tests.id('j_ok')), 'APP_ACTION', 'status_source = APP_ACTION');
select is((select count(*)::int from public.application_status_history h join public.applications a on a.id = h.application_id where a.graduate_id = tests.id('a1')), 1, 'history row written');
select is((select count(*)::int from public.notifications where profile_id = tests.id('a1') and type = 'APPLICATION_SUBMITTED'), 1, 'notification written');
select tests.login('a1');
select throws_ok($q$select public.apply_for_job(tests.id('j_ok'))$q$, 'PT409', 'ALREADY_APPLIED', 'duplicate application');
select throws_ok($q$select public.apply_for_job(tests.id('j_exp'))$q$, 'PT422', 'OPPORTUNITY_CLOSED', 'expired deadline');
select throws_ok($q$select public.apply_for_job(tests.id('j_closed'))$q$, 'PT422', 'OPPORTUNITY_CLOSED', 'status CLOSED');
select throws_ok($q$select public.apply_for_job(tests.id('t_training'))$q$, 'PT422', 'NOT_APPLICATION_OPPORTUNITY',
  'TRAINING is not an application opportunity');
select throws_ok($q$select public.apply_for_job(gen_random_uuid())$q$, 'PT404', 'OPPORTUNITY_NOT_FOUND', 'unknown opportunity');
select throws_ok($q$select public.apply_for_job(tests.id('j_cert'))$q$, 'PT422', 'NOT_ELIGIBLE', 'mandatory certification missing');
select is((select count(*)::int from public.applications where graduate_id = tests.id('a1')), 1, 'rejected attempts created no rows');
select is(public.get_opportunity_eligibility(tests.id('j_cert')), array['MISSING_CERTIFICATION:Security+'], 'eligibility failures are reported');
reset role;
insert into public.certifications (graduate_id, title) values (tests.id('a1'), 'security+');
select tests.login('a1');
select is((public.apply_for_job(tests.id('j_cert'))).status, 'SUBMITTED', 'eligible once certification exists (case-insensitive)');
select throws_ok($q$select public.apply_for_job(tests.id('j_ok'), '00000000-0000-0000-0000-0000000000c2')$q$, 'PT404', 'CV_NOT_FOUND', 'cannot attach another graduate''s CV (and duplicate check is not reached first)');

-- withdraw_application
select is((public.withdraw_application((select id from public.applications where opportunity_id = tests.id('j_ok')))).status, 'WITHDRAWN', 'withdraw own SUBMITTED application');
select throws_ok($q$select public.withdraw_application((select id from public.applications where opportunity_id = tests.id('j_ok')))$q$, 'PT422', 'CANNOT_WITHDRAW', 'withdrawing twice');
select throws_ok($q$select public.apply_for_job(tests.id('j_ok'))$q$, 'PT409', 'ALREADY_APPLIED', 'cannot re-apply after withdrawing (BR-007)');
reset role;
select is((select count(*)::int from public.application_status_history h join public.applications a on a.id = h.application_id where a.opportunity_id = tests.id('j_ok')), 2, 'withdraw recorded in history');
select tests.login('a1');
select throws_ok($q$select public.withdraw_application('00000000-0000-0000-0000-0000000000d2')$q$, 'PT404', 'APPLICATION_NOT_FOUND', 'cannot withdraw another graduate''s application');
select tests.login('a2');
select throws_ok($q$select public.withdraw_application('00000000-0000-0000-0000-0000000000d2')$q$, 'PT422', 'CANNOT_WITHDRAW', 'sample (seed) application cannot be withdrawn');

-- set_current_job
select tests.login('a1');
select is((public.set_current_job('Acme', 'Analyst', date '2024-01-01')).is_current, true, 'first job is current');
reset role;
select is((select employment_status from public.graduate_profiles where profile_id = tests.id('a1')), 'EMPLOYED', 'status -> EMPLOYED');
select tests.login('a1');
select public.set_current_job('Globex', 'Senior Analyst', date '2025-06-01');
reset role;
select is((select count(*)::int from public.career_history where graduate_id = tests.id('a1') and is_current), 1, 'exactly one current job');
select is((select end_date from public.career_history where graduate_id = tests.id('a1') and company_name = 'Acme'), date '2025-06-01', 'previous job closed at new start date');
select is((select count(*)::int from public.career_history where graduate_id = tests.id('a1')), 2, 'history preserved');
select tests.login('a1');
select throws_ok($q$select public.set_current_job('Initech', 'X', date '2020-01-01')$q$, 'PT422', 'START_BEFORE_PREVIOUS', 'start before previous job');
select throws_ok($q$select public.set_current_job('  ', 'X', date '2026-01-01')$q$, 'PT422', 'INVALID_INPUT', 'blank company');
reset role;
select is((select company_name from public.career_history where graduate_id = tests.id('a1') and is_current), 'Globex', 'failed attempts changed nothing');

-- confirm_cv_suggestions
do $$ declare cv uuid := gen_random_uuid(); cv2 uuid := gen_random_uuid(); begin
  insert into public.cv_documents (id, graduate_id, storage_path, file_type, size_bytes) values (cv, tests.id('a1'), tests.id('a1')::text || '/c.pdf', 'pdf', 10);
  insert into public.cv_suggestions (id, graduate_id, cv_document_id, kind, payload) values
    ('00000000-0000-0000-0000-0000000000a1', tests.id('a1'), cv, 'SKILL', '{"skill_id":"T_SKILL_A"}'),
    ('00000000-0000-0000-0000-0000000000a2', tests.id('a1'), cv, 'SKILL', '{"skill_id":"T_SKILL_B","level":4}');
  insert into public.cv_documents (id, graduate_id, storage_path, file_type, size_bytes) values (cv2, tests.id('a2'), tests.id('a2')::text || '/d.pdf', 'pdf', 10);
  insert into public.cv_suggestions (id, graduate_id, cv_document_id, kind, payload) values
    ('00000000-0000-0000-0000-0000000000b1', tests.id('a2'), cv2, 'SKILL', '{"skill_id":"T_SKILL_A"}');
end $$;
select tests.login('a1');
select is(public.confirm_cv_suggestions(array['00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1']::uuid[], array['00000000-0000-0000-0000-0000000000a2']::uuid[]),
          '{"confirmed": 1, "rejected": 1}'::jsonb, 'confirms own, rejects own, ignores another graduate''s id');
reset role;
select is((select source from public.graduate_skills where graduate_id = tests.id('a1') and skill_id = 'T_SKILL_A'), 'CV_CONFIRMED', 'confirmed skill stored as CV_CONFIRMED');
select is((select count(*)::int from public.graduate_skills where graduate_id = tests.id('a1') and skill_id = 'T_SKILL_B'), 0, 'rejected suggestion never becomes a skill');
select is((select status from public.cv_suggestions where id = '00000000-0000-0000-0000-0000000000b1'), 'PENDING', 'other graduate''s suggestion untouched');

-- insights are scoped to the caller
select tests.login('a1');
select is((public.get_my_insights() -> 'applications' ->> 'total')::int, 2, 'insights count only own applications');
select ok((public.get_my_insights() -> 'profile_completion' -> 'missing_fields') ? 'college', 'insights safely report missing profile fields');
select ok(jsonb_array_length(public.get_my_insights() -> 'profile_completion' -> 'missing_fields') > 0, 'missing fields are returned as a JSON array');

reset role;
select * from finish();
rollback;
