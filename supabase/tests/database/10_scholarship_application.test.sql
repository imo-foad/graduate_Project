begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_k
$f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end
$f$;
create function tests.mk_opp(p_key text, p_type text, p_props jsonb default '{}') returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.opportunities (seed_key, type, title, status, deadline, end_at, attendance_mode)
  values ('t-' || p_key, p_type, 'Test ' || p_key, coalesce(p_props ->> 'status', 'ACTIVE'),
    case when p_props ? 'deadline_days' then now() + make_interval(days => (p_props ->> 'deadline_days')::int) end,
    case when p_props ? 'end_days' then now() + make_interval(days => (p_props ->> 'end_days')::int) end, 'ONLINE')
  returning id into v;
  insert into tests.ids values (p_key, v);
  return v;
end
$f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end
$f$;

do $$
begin
  perform tests.mk_user('a1'); perform tests.mk_user('a2');
  perform tests.mk_opp('s_ok', 'SCHOLARSHIP', '{"deadline_days":5}');
  perform tests.mk_opp('s_expired', 'SCHOLARSHIP', '{"deadline_days":-1}');
  perform tests.mk_opp('s_closed', 'SCHOLARSHIP', '{"deadline_days":5,"status":"CLOSED"}');
  perform tests.mk_opp('s_ended', 'SCHOLARSHIP', '{"end_days":-1}');
  perform tests.mk_opp('s_elig', 'SCHOLARSHIP', '{"deadline_days":5}');
  perform tests.mk_opp('s_validation', 'SCHOLARSHIP', '{"deadline_days":5}');
  perform tests.mk_opp('c_comp', 'COMPETITION', '{"deadline_days":5}');
  perform tests.mk_opp('j_job', 'JOB', '{"deadline_days":5}');
  insert into public.opportunity_eligibility(opportunity_id, allowed_degrees)
    values (tests.id('s_elig'), array['Master']);
  update public.graduate_profiles set degree = 'Bachelor' where profile_id = tests.id('a1');
  insert into public.cv_documents(id, graduate_id, storage_path, file_type, size_bytes)
    values ('00000000-0000-0000-0000-0000000000c1', tests.id('a1'), tests.id('a1')::text || '/a.pdf', 'pdf', 100),
           ('00000000-0000-0000-0000-0000000000c2', tests.id('a2'), tests.id('a2')::text || '/b.pdf', 'pdf', 100);
  insert into tests.ids values
    ('cv_a', '00000000-0000-0000-0000-0000000000c1'),
    ('cv_b', '00000000-0000-0000-0000-0000000000c2');
end
$$;

select ok(has_table_privilege('authenticated', 'public.scholarship_applications', 'SELECT'), 'authenticated can read own applications');
select ok(not has_table_privilege('authenticated', 'public.scholarship_applications', 'INSERT'), 'direct insert denied');
select ok(not has_table_privilege('authenticated', 'public.scholarship_applications', 'UPDATE'), 'direct update denied');
select ok(not has_table_privilege('authenticated', 'public.scholarship_applications', 'DELETE'), 'direct delete denied');

select tests.login('a1');
select is((public.apply_for_scholarship(
  tests.id('s_ok'), tests.id('cv_a'), 'I want to study advanced computing.',
  '{"study_area":"Computer Science","motivation":"Research"}'::jsonb
)).status, 'SUBMITTED', 'eligible graduate submits scholarship application');
reset role;
insert into tests.ids(k,v)
select 'app_s_ok', id from public.scholarship_applications
 where graduate_id=tests.id('a1') and opportunity_id=tests.id('s_ok');
select is((select count(*)::int from public.scholarship_applications where graduate_id=tests.id('a1') and opportunity_id=tests.id('s_ok')), 1, 'one row persisted');
select is((select cv_document_id from public.scholarship_applications where opportunity_id=tests.id('s_ok')), tests.id('cv_a'), 'owned CV attached');
select is((select application_data from public.scholarship_applications where opportunity_id=tests.id('s_ok')),
  '{"study_area":"Computer Science","motivation":"Research"}'::jsonb, 'form answers persisted');
select is((select count(*)::int from public.scholarship_application_status_history h join public.scholarship_applications a on a.id=h.scholarship_application_id where a.opportunity_id=tests.id('s_ok') and h.new_status='SUBMITTED'), 1, 'submission audited');
select is((select count(*)::int from public.notifications where profile_id=tests.id('a1') and type='SCHOLARSHIP_APPLICATION_SUBMITTED'), 1, 'submission notification created');
select is((select count(*)::int from public.recommendation_interactions where graduate_id=tests.id('a1') and opportunity_id=tests.id('s_ok') and interaction_type='APPLY'), 1, 'APPLY interaction logged');

select tests.login('a1');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_ok'))$q$, 'PT409', 'ALREADY_APPLIED', 'duplicate submission rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_expired'))$q$, 'PT422', 'OPPORTUNITY_CLOSED', 'expired deadline rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_closed'))$q$, 'PT422', 'OPPORTUNITY_CLOSED', 'closed opportunity rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_ended'))$q$, 'PT422', 'OPPORTUNITY_CLOSED', 'ended opportunity rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('c_comp'))$q$, 'PT422', 'NOT_A_SCHOLARSHIP', 'competition rejected by scholarship RPC');
select throws_ok($q$select public.apply_for_scholarship(tests.id('j_job'))$q$, 'PT422', 'NOT_A_SCHOLARSHIP', 'job rejected by scholarship RPC');
select throws_ok($q$select public.apply_for_scholarship(gen_random_uuid())$q$, 'PT404', 'OPPORTUNITY_NOT_FOUND', 'unknown id rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_elig'))$q$, 'PT422', 'NOT_ELIGIBLE', 'degree eligibility checked');
select is(public.get_opportunity_eligibility(tests.id('s_elig')), array['DEGREE_NOT_ALLOWED'], 'eligibility failure reported');
select is((select count(*)::int from public.scholarship_applications where graduate_id=tests.id('a1') and opportunity_id<>tests.id('s_ok')), 0, 'failed attempts create no rows');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'), tests.id('cv_b'))$q$, 'PT404', 'CV_NOT_FOUND', 'cannot attach another graduate CV');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'), null, null, '[]'::jsonb)$q$, 'PT422', 'INVALID_INPUT', 'application data must be object');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'), null, null, jsonb_build_object('answer',repeat('x',33000)))$q$, 'PT422', 'INVALID_INPUT', 'oversized data rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'), null, repeat('x',10001))$q$, 'PT422', 'INVALID_INPUT', 'oversized statement rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'), null, null, null)$q$, 'PT422', 'INVALID_INPUT', 'null data rejected');

select is((public.withdraw_scholarship_application((select id from public.scholarship_applications where opportunity_id=tests.id('s_ok')))).status,
  'WITHDRAWN', 'owner withdraws submitted application');
select throws_ok($q$select public.withdraw_scholarship_application((select id from public.scholarship_applications where opportunity_id=tests.id('s_ok')))$q$,
  'PT422', 'CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION', 'second withdrawal rejected');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_ok'))$q$, 'PT409', 'ALREADY_APPLIED', 'cannot re-submit after withdrawal');
reset role;
select is((select count(*)::int from public.scholarship_application_status_history h join public.scholarship_applications a on a.id=h.scholarship_application_id where a.opportunity_id=tests.id('s_ok')), 2, 'withdrawal audited');
select is((select count(*)::int from public.notifications where profile_id=tests.id('a1') and type='SCHOLARSHIP_APPLICATION_WITHDRAWN'), 1, 'withdrawal notification created');

update public.opportunities set status='CLOSED' where id=tests.id('s_ok');
select tests.login('a1');
select is((select count(*)::int from public.scholarship_applications where opportunity_id=tests.id('s_ok')), 1, 'owner reads own application');
select is((select count(*)::int from public.scholarship_application_status_history h join public.scholarship_applications a on a.id=h.scholarship_application_id where a.opportunity_id=tests.id('s_ok')), 2, 'owner reads own history');
select ok(exists(select 1 from public.opportunities where id=tests.id('s_ok')), 'applicant sees closed scholarship');
select throws_ok($q$insert into public.scholarship_applications(opportunity_id,graduate_id) values(tests.id('s_validation'),tests.id('a1'))$q$, '42501', null, 'direct insert denied');
select throws_ok($q$update public.scholarship_applications set status='WITHDRAWN' where opportunity_id=tests.id('s_ok')$q$, '42501', null, 'direct status update denied');
select throws_ok($q$delete from public.scholarship_applications where opportunity_id=tests.id('s_ok')$q$, '42501', null, 'direct delete denied');
select tests.login('a2');
select is((select count(*)::int from public.scholarship_applications where opportunity_id=tests.id('s_ok')), 0, 'peer cannot read application');
select is((select count(*)::int from public.scholarship_application_status_history h join public.scholarship_applications a on a.id=h.scholarship_application_id where a.opportunity_id=tests.id('s_ok')), 0, 'peer cannot read status history');
select throws_ok($q$select public.withdraw_scholarship_application(tests.id('app_s_ok'))$q$,
  'PT404', 'SCHOLARSHIP_APPLICATION_NOT_FOUND', 'peer cannot withdraw application');
select set_config('request.jwt.claims', '', true);
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'))$q$, 'PT401', 'UNAUTHENTICATED', 'missing JWT rejected');
reset role;
select set_config('role', 'anon', true);
select throws_ok($q$select count(*) from public.scholarship_applications$q$, '42501', null, 'anon cannot read scholarship applications');
select throws_ok($q$select public.apply_for_scholarship(tests.id('s_validation'))$q$, '42501', null, 'anon cannot call scholarship RPC');
reset role;
select * from finish();
rollback;
