begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select, insert on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;
create function tests.mk_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.login(p_key text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tests.id(p_key), 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $f$;

do $$ declare v_company uuid; v_job uuid; begin
  perform tests.mk_user('owner');
  perform tests.mk_user('graduate');
  perform tests.mk_user('admin');
  perform tests.mk_user('outsider');
end $$;

select tests.login('owner');
insert into tests.ids values ('company', (public.create_company('Acme Labs', 'https://acme.example', 'Test employer')).id);
insert into tests.ids values ('job', (public.create_company_job(
  tests.id('company'), 'Backend Engineer', 'Build and maintain backend services.',
  'Cairo', 'HYBRID', now() + interval '10 days', 'FULL_TIME', 'JUNIOR'
)).id);
select is((select verification_status from public.companies where id = tests.id('company')), 'PENDING_REVIEW', 'new company waits for admin verification');
select is((select status from public.opportunities where id = tests.id('job')), 'DRAFT', 'company job starts as draft');
select throws_ok($$select public.publish_company_job(tests.id('job'))$$, 'PT422', 'COMPANY_NOT_VERIFIED', 'unverified company cannot publish');

reset role;
insert into private.platform_admins(user_id) values (tests.id('admin'));
select tests.login('admin');
select is((public.review_company(tests.id('company'), 'VERIFIED', 'Documents reviewed')).verification_status, 'VERIFIED', 'platform admin verifies company');
select is((select count(*)::int from public.company_verification_history where company_id = tests.id('company')), 1, 'verification decision is audited');

reset role;
select tests.login('owner');
select is((public.publish_company_job(tests.id('job'))).status, 'ACTIVE', 'verified company can publish job');
select is((public.update_company_job(tests.id('job'), 'Senior Backend Engineer', 'Own backend API design and delivery.', 'Giza', 'ONSITE', now() + interval '12 days')).title,
  'Senior Backend Engineer', 'company member can edit own job');
select is((public.close_company_job(tests.id('job'))).status, 'CLOSED', 'company can close its own job');

-- Reopen a fresh job for a real graduate application and status update.
insert into tests.ids values ('job2', (public.create_company_job(
  tests.id('company'), 'Android Engineer', 'Build native Android apps with Kotlin.',
  'Mansoura', 'ONLINE', now() + interval '20 days', 'FULL_TIME', 'FRESH_GRADUATE'
)).id);
select is((public.publish_company_job(tests.id('job2'))).status, 'ACTIVE', 'second job can be published');

reset role;
select tests.login('graduate');
insert into tests.ids values ('application', (public.apply_for_job(tests.id('job2'), null, 'Please consider my application.')).id);
select is((select status from public.applications where id = tests.id('application')), 'SUBMITTED', 'graduate submits application');

reset role;
select tests.login('outsider');
select throws_ok($$select public.update_application_status(tests.id('application'), 'UNDER_REVIEW', null)$$,
  'PT403', 'NOT_COMPANY_MEMBER', 'unrelated user cannot update application status');

reset role;
select tests.login('owner');
select is((public.update_application_status(tests.id('application'), 'UNDER_REVIEW', 'CV reviewed')).status,
  'UNDER_REVIEW', 'company recruiter can update its own application');
select is((select source_type from public.application_status_history where application_id = tests.id('application') order by changed_at desc limit 1),
  'COMPANY_ACTION', 'company action is added to status history');
reset role;
select tests.login('graduate');
select ok(exists (select 1 from public.notifications where profile_id = tests.id('graduate')
  and type = 'APPLICATION_STATUS_UPDATED'), 'graduate receives in-app status notification');

select throws_ok($$insert into public.companies(name, created_by) values ('forged', tests.id('owner'))$$,
  '42501', null, 'company table cannot be written directly');
select throws_ok($$update public.applications set status = 'ACCEPTED' where id = tests.id('application')$$,
  '42501', null, 'company status changes must use the guarded RPC');

reset role;
select tests.login('graduate');
select is((select count(*)::int from public.applications where id = tests.id('application')), 1, 'graduate still sees own application');
reset role;
select tests.login('outsider');
select is((select count(*)::int from public.applications where id = tests.id('application')), 0, 'unrelated user cannot see graduate application');
reset role;
select * from finish();
rollback;
