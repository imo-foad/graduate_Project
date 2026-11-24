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

do $$ begin
  perform tests.mk_user('owner');
  perform tests.mk_user('recruiter');
  perform tests.mk_user('viewer');
  perform tests.mk_user('admin');
  perform tests.mk_user('outsider');
end $$;

select tests.login('owner');
insert into tests.ids values ('company', (public.create_company('Acme Labs')).id);
select is((public.set_company_member(tests.id('company'), tests.id('recruiter'), 'RECRUITER', true)).role,
  'RECRUITER', 'owner can add a recruiter');
select is((public.set_company_member(tests.id('company'), tests.id('viewer'), 'VIEWER', true)).role,
  'VIEWER', 'owner can add a viewer');

reset role;
select tests.login('recruiter');
insert into tests.ids values ('recruiter_job', (public.create_company_job(
  tests.id('company'), 'Platform Engineer', 'Build and operate platform services.',
  'Cairo', 'HYBRID', now() + interval '15 days', 'FULL_TIME', 'JUNIOR'
)).id);
select is((select status from public.opportunities where id = tests.id('recruiter_job')), 'DRAFT',
  'recruiter can create a company job');

reset role;
select tests.login('viewer');
select throws_ok($$select public.create_company_job(
  tests.id('company'), 'Viewer Job', 'This viewer must not publish company jobs.',
  null, 'ONSITE', null, 'FULL_TIME', 'JUNIOR')$$,
  'PT403', 'NOT_COMPANY_MEMBER', 'viewer cannot create a job');

reset role;
select tests.login('owner');
select is((public.set_company_member(tests.id('company'), tests.id('recruiter'), 'RECRUITER', false)).is_active,
  false, 'owner can revoke a recruiter');
reset role;
select tests.login('recruiter');
select throws_ok($$select public.create_company_job(
  tests.id('company'), 'Revoked Job', 'A revoked recruiter cannot create jobs.',
  null, 'ONSITE', null, 'FULL_TIME', 'JUNIOR')$$,
  'PT403', 'NOT_COMPANY_MEMBER', 'revoked recruiter loses company access');

reset role;
insert into private.platform_admins(user_id) values (tests.id('admin'));
select tests.login('admin');
insert into tests.ids values ('admin_job', (public.create_admin_job(
  'Data Engineer', 'Acme Platform', 'Operate data pipelines and platform services.',
  'Alexandria', 'ONSITE', now() + interval '30 days', 'FULL_TIME', 'JUNIOR'
)).id);
select is((select status from public.opportunities where id = tests.id('admin_job')), 'DRAFT',
  'admin job is created as a draft');
select is((public.publish_admin_job(tests.id('admin_job'))).status, 'ACTIVE',
  'platform admin can publish a platform job');
select is((public.update_admin_job(tests.id('admin_job'), 'Senior Data Engineer', 'Acme Platform',
  'Lead data platform delivery and reliability.', 'Cairo', 'HYBRID', now() + interval '40 days')).title,
  'Senior Data Engineer', 'platform admin can edit a published job');
select is((public.close_admin_job(tests.id('admin_job'))).status, 'CLOSED',
  'platform admin can close a published job');

reset role;
select tests.login('outsider');
select throws_ok($$select public.create_admin_job(
  'Fake Job', 'Fake Co', 'An outsider must not create platform jobs.',
  null, 'ONSITE', null, 'FULL_TIME', 'JUNIOR')$$,
  'PT403', 'ADMIN_REQUIRED', 'ordinary user cannot create a platform job');

reset role;
select * from finish();
rollback;
