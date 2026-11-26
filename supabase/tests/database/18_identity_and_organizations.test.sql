-- 0028: phone-first registration, multiple verified human identities, and organization role hardening.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_k text) returns uuid language sql stable as $f$ select v from tests.ids where k = p_k $f$;

-- Synthetic phone-only Auth user: the trigger must create a PENDING profile without fabricating an email.
create function tests.mk_phone_user(p_key text, p_phone text, p_confirmed boolean default false)
returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, phone, phone_confirmed_at, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_phone,
          case when p_confirmed then now() end, jsonb_build_object('full_name', p_key));
  insert into tests.ids values (p_key, v);
  return v;
end $f$;
create function tests.mk_email_user(p_key text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, email_confirmed_at, raw_user_meta_data)
  values (v, 'authenticated', 'authenticated', p_key || '@tests.local', now(), jsonb_build_object('full_name', p_key));
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

-- ---- 1. Phone-first profile model, with no fabricated email -----------------------------------------
select tests.mk_phone_user('pending_u', '+201000000001', false);
select is((select email from public.profiles where id = tests.id('pending_u')), null,
  'a phone-only account gets no fabricated email');
select is((select account_status from public.profiles where id = tests.id('pending_u')), 'PENDING_VERIFICATION',
  'a phone-only account starts PENDING_VERIFICATION');
select throws_ok(
  format($$ update public.profiles set phone = 'not-e164' where id = %L $$, tests.id('pending_u')),
  '23514', null, 'an invalid phone number is rejected by the profile constraint'
);

-- ---- 2. Only the service role writes verification and identities ------------------------------------
select is(has_function_privilege('authenticated', 'public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb)', 'execute'), false,
  'authenticated cannot record its own National-ID verification');
select is(has_function_privilege('service_role', 'public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb)', 'execute'), true,
  'service_role records verification results');
select is(has_table_privilege('authenticated', 'public.human_identities', 'insert'), false,
  'authenticated cannot insert its own identity rows');
select is(has_table_privilege('authenticated', 'public.human_identities', 'update'), false,
  'authenticated cannot grant itself a verified role');
select is(has_table_privilege('authenticated', 'public.human_identities', 'select'), true,
  'authenticated can read its own identities (RLS-scoped)');

-- Rejected verification creates no identity.
select is(public.record_identity_verification(
  tests.id('pending_u'), 'mock-institutional-identity', null,
  repeat('a', 64), '4567', '[]'::jsonb, 'REJECTED', 'NATIONAL_ID_NOT_FOUND') ->> 'status',
  'REJECTED', 'a rejected verification is recorded');
select is((select count(*)::int from public.human_identities where profile_id = tests.id('pending_u')), 0,
  'a rejected verification grants no identity');

-- Verified verification writes every identity from the institution (multi-identity account).
select is(public.record_identity_verification(
  tests.id('pending_u'), 'mock-institutional-identity', 'synthetic:4567',
  repeat('b', 64), '4567',
  '[{"identity_type":"STUDENT","institution_ref":"CAIRO_UNIVERSITY_SYNTHETIC","attributes":{"year":3}},
    {"identity_type":"FACULTY","institution_ref":"AIN_SHAMS_UNIVERSITY_SYNTHETIC","attributes":{}}]'::jsonb,
  'VERIFIED', null) ->> 'verified_identities',
  '2', 'two verified identities are recorded for one account');
select is((select count(*)::int from public.human_identities where profile_id = tests.id('pending_u') and status = 'VERIFIED'), 2,
  'the account holds both verified affiliations');
select is((select count(*)::int from public.graduate_profiles where profile_id = tests.id('pending_u')), 0,
  'STUDENT/FACULTY-only accounts do not receive graduate career profiles');

-- One institutional person cannot be linked to a second account.
select tests.mk_phone_user('second_u', '+201000000002', false);
select throws_ok(
  format($$ select public.record_identity_verification(%L, 'mock-institutional-identity', null, %L, '4567', '[{"identity_type":"GRADUATE","institution_ref":"CAIRO_UNIVERSITY_SYNTHETIC"}]'::jsonb, 'VERIFIED') $$,
         tests.id('second_u'), repeat('b', 64)),
  'PT409', 'IDENTITY_ALREADY_LINKED',
  'the same keyed National-ID digest cannot be linked to two accounts'
);
-- Unknown role strings from a provider are rejected, never trusted.
select throws_ok(
  format($$ select public.record_identity_verification(%L, 'mock-institutional-identity', null, %L, '9999', '[{"identity_type":"ADMIN","institution_ref":"X"}]'::jsonb, 'VERIFIED') $$,
         tests.id('second_u'), repeat('c', 64)),
  'PT422', 'INVALID_IDENTITY',
  'an unsupported provider role is rejected'
);

-- ---- 3. Phone OTP + institutional identity are both required before activation ----------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('pending_u'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(tests.as_user(tests.id('pending_u'), 'select public.finalize_registration()'), 'PT409', 'PHONE_NOT_VERIFIED',
  'registration cannot complete before the phone OTP is confirmed');
select throws_ok(tests.as_user(tests.id('pending_u'), 'select public.get_my_insights()'), 'PT403', 'ACCOUNT_UNAVAILABLE',
  'a pending account is blocked from normal RPCs');
select is((select count(*)::int from public.list_my_identities()), 2,
  'the pending owner can still read their own verified identities');
reset role;

-- Confirm OTP (simulating Supabase Auth) and finalize.
update auth.users set phone_confirmed_at = now() where id = tests.id('pending_u');
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('pending_u'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is(public.finalize_registration() ->> 'account_status', 'ACTIVE',
  'OTP + verified identity activate the account');
select is((select account_status from public.profiles where id = tests.id('pending_u')), 'ACTIVE',
  'the profile status becomes ACTIVE');
select is((select phone_verified_at is not null from public.profiles where id = tests.id('pending_u')), true,
  'the verified phone timestamp is recorded');
reset role;

-- A second account with a verified identity but no OTP still cannot activate.
select tests.mk_phone_user('no_otp_u', '+201000000003', false);
select public.record_identity_verification(
  tests.id('no_otp_u'), 'mock-institutional-identity', null, repeat('d', 64), '4444',
  '[{"identity_type":"GRADUATE","institution_ref":"CAIRO_UNIVERSITY_SYNTHETIC"}]'::jsonb, 'VERIFIED', null);
select is((select count(*)::int from public.graduate_profiles where profile_id = tests.id('no_otp_u')), 1,
  'a verified GRADUATE identity provisions exactly one graduate profile');
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('no_otp_u'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(tests.as_user(tests.id('no_otp_u'), 'select public.finalize_registration()'), 'PT409', 'PHONE_NOT_VERIFIED',
  'a verified identity without phone OTP does not activate the account');
reset role;

-- ---- 4. Identity RLS: another user cannot read these affiliations ----------------------------------
select tests.mk_phone_user('other_u', '+201000000004', false);
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('other_u'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.human_identities where profile_id = tests.id('pending_u')), 0,
  'RLS hides another human''s verified identities');
select is((select count(*)::int from public.list_my_identities()), 0,
  'list_my_identities is always caller-scoped');
reset role;

-- ---- 5. Organization roles: VIEWER is read-only; owner transfers are safe ---------------------------
select tests.mk_email_user('owner');
select tests.mk_email_user('recruiter');
select tests.mk_email_user('viewer');
select tests.mk_email_user('outsider');

insert into public.companies (id, name, created_by, verification_status)
values ('11111111-1111-4111-8111-111111111111', 'Synthetic Verified Company', tests.id('owner'), 'VERIFIED');
insert into public.company_memberships (company_id, user_id, role) values
  ('11111111-1111-4111-8111-111111111111', tests.id('owner'), 'OWNER'),
  ('11111111-1111-4111-8111-111111111111', tests.id('recruiter'), 'RECRUITER'),
  ('11111111-1111-4111-8111-111111111111', tests.id('viewer'), 'VIEWER');

insert into public.opportunities (id, seed_key, type, title, status, company_id, created_by, deadline)
values ('22222222-2222-4222-8222-222222222222', 't-org-job', 'JOB', 'Synthetic company job', 'ACTIVE',
        '11111111-1111-4111-8111-111111111111', tests.id('owner'), now() + interval '10 days');
insert into public.applications (id, opportunity_id, graduate_id, status)
values ('33333333-3333-4333-8333-333333333333', '22222222-2222-4222-8222-222222222222', tests.id('viewer'), 'SUBMITTED');

-- VIEWER cannot process an application.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('viewer'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(
  tests.as_user(tests.id('viewer'), $$ select public.update_application_status('33333333-3333-4333-8333-333333333333', 'UNDER_REVIEW') $$),
  'PT403', 'NOT_COMPANY_MEMBER',
  'a VIEWER cannot process an application'
);
-- VIEWER cannot publish or create company opportunities either.
select throws_ok(
  tests.as_user(tests.id('viewer'), format('select public.publish_company_job(%L)', '22222222-2222-4222-8222-222222222222')),
  'PT403', 'NOT_COMPANY_MEMBER',
  'a VIEWER cannot publish a company opportunity'
);
select throws_ok(
  tests.as_user(tests.id('viewer'), format($$ select public.set_company_member(%L, %L, 'OWNER', true) $$,
         '11111111-1111-4111-8111-111111111111', tests.id('viewer'))),
  'PT403', 'NOT_COMPANY_MEMBER',
  'a VIEWER cannot change memberships'
);
reset role;

-- OWNER can manage a member but cannot grant OWNER or change themselves.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('owner'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(
  tests.as_user(tests.id('owner'), format($$ select public.set_company_member(%L, %L, 'OWNER', true) $$,
         '11111111-1111-4111-8111-111111111111', tests.id('viewer'))),
  'PT422', 'INVALID_INPUT',
  'an OWNER cannot grant the OWNER role through set_company_member'
);
select throws_ok(
  tests.as_user(tests.id('owner'), format($$ select public.set_company_member(%L, %L, 'RECRUITER', true) $$,
         '11111111-1111-4111-8111-111111111111', tests.id('owner'))),
  'PT422', 'INVALID_INPUT',
  'a user cannot change their own membership'
);
select is((public.transfer_company_ownership(
  '11111111-1111-4111-8111-111111111111', tests.id('recruiter'))).role, 'OWNER',
  'the current OWNER can transfer ownership to an existing active member');
reset role;
select is((select role from public.company_memberships
            where company_id = '11111111-1111-4111-8111-111111111111' and user_id = tests.id('owner')),
  'RECRUITER', 'the previous owner is demoted to RECRUITER');
select is((select count(*)::int from public.company_memberships
            where company_id = '11111111-1111-4111-8111-111111111111' and role = 'OWNER' and is_active),
  1, 'exactly one active OWNER remains');
select is((select count(*)::int from private.company_role_audit
            where company_id = '11111111-1111-4111-8111-111111111111' and action = 'OWNERSHIP_TRANSFERRED'),
  1, 'ownership transfer is audited');

-- An outsider cannot transfer or manage memberships.
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('outsider'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select throws_ok(
  tests.as_user(tests.id('outsider'), format($$ select public.transfer_company_ownership(%L, %L) $$,
         '11111111-1111-4111-8111-111111111111', tests.id('viewer'))),
  'PT403', 'NOT_COMPANY_MEMBER',
  'a non-member cannot transfer company ownership'
);
reset role;

-- ---- 6. Pending accounts are blocked at the RLS layer too ------------------------------------------
select set_config('request.jwt.claims', jsonb_build_object('sub', tests.id('no_otp_u'), 'role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.opportunities), 0,
  'a PENDING_VERIFICATION account reads no catalogue rows through RLS');
reset role;

select * from finish();
rollback;
