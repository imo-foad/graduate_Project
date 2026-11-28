-- 0043: protect pre-ledger recovery and enforce idempotent, bounded confirmation-email retries.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.ids (k text primary key, v uuid not null);
grant select on tests.ids to anon, authenticated, service_role;
create function tests.id(p_key text) returns uuid language sql stable as $f$
  select v from tests.ids where k = p_key
$f$;
create function tests.mk_pending_registration(p_key text, p_digest text) returns uuid language plpgsql as $f$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_user_meta_data, raw_app_meta_data)
  values (
    v_id, 'authenticated', 'authenticated', p_key || '@tests.local',
    jsonb_build_object('full_name', p_key, 'registration_flow', 'EMAIL_IDENTITY_VERIFICATION'),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'),
                       'registration_synthetic_digest', p_digest)
  );
  insert into tests.ids values (p_key, v_id);
  return v_id;
end
$f$;

select tests.mk_pending_registration('orphan', repeat('a', 64));
select is((select account_status from public.profiles where id = tests.id('orphan')),
  'PENDING_VERIFICATION', 'the Auth trigger creates a pending profile for an email registration');

-- Orphan recovery requires both the email and the trusted app_metadata digest.
select is(public.find_unlinked_pending_email_registration_retry('orphan@tests.local', repeat('a', 64))::text,
  tests.id('orphan')::text, 'an orphaned profile can be recovered by its exact email and synthetic digest');
select is(public.find_unlinked_pending_email_registration_retry('orphan@tests.local', repeat('b', 64)),
  null::uuid, 'a different synthetic digest cannot recover the same orphaned email account');
select is(has_function_privilege('anon',
  'public.find_unlinked_pending_email_registration_retry(text,text)', 'execute'), false,
  'anon cannot call orphan recovery');
select is(has_function_privilege('authenticated',
  'public.find_unlinked_pending_email_registration_retry(text,text)', 'execute'), false,
  'authenticated cannot call orphan recovery');
select is(has_function_privilege('service_role',
  'public.find_unlinked_pending_email_registration_retry(text,text)', 'execute'), true,
  'service_role can call exact-match orphan recovery');

-- The first request claims a send; a normal duplicate request is idempotent and does not resend.
create table tests.first_claim as
select public.claim_registration_email_confirmation(tests.id('orphan'), false, 60, 2) as body;
select is((select body ->> 'allowed' from tests.first_claim), 'true',
  'the first confirmation request is allowed');
select is((select body ->> 'reason' from tests.first_claim), 'FIRST_REQUEST',
  'the first confirmation request is identified separately');

create table tests.duplicate_claim as
select public.claim_registration_email_confirmation(tests.id('orphan'), false, 60, 2) as body;
select is((select body ->> 'allowed' from tests.duplicate_claim), 'false',
  'a duplicate registration request does not claim another send');
select is((select body ->> 'reason' from tests.duplicate_claim), 'ALREADY_REQUESTED',
  'a duplicate registration request returns the already-requested state');

-- Explicit resends are subject to a cooldown and a bounded attempt budget.
create table tests.cooldown_claim as
select public.claim_registration_email_confirmation(tests.id('orphan'), true, 60, 2) as body;
select is((select body ->> 'reason' from tests.cooldown_claim), 'COOLDOWN',
  'an explicit resend inside the cooldown is rejected');
select ok(((select body ->> 'retry_after_seconds' from tests.cooldown_claim)::integer) > 0,
  'the cooldown response provides a positive retry delay');

update private.registration_email_send_attempts
   set last_attempt_at = clock_timestamp() - interval '61 seconds'
 where profile_id = tests.id('orphan');
create table tests.second_send as
select public.claim_registration_email_confirmation(tests.id('orphan'), true, 60, 2) as body;
select is((select body ->> 'allowed' from tests.second_send), 'true',
  'an explicit resend is allowed after the cooldown');
select is((select body ->> 'attempt_count' from tests.second_send), '2',
  'the explicit resend consumes exactly one additional attempt');

update private.registration_email_send_attempts
   set last_attempt_at = clock_timestamp() - interval '61 seconds'
 where profile_id = tests.id('orphan');
create table tests.exhausted_claim as
select public.claim_registration_email_confirmation(tests.id('orphan'), true, 60, 2) as body;
select is((select body ->> 'reason' from tests.exhausted_claim), 'MAX_ATTEMPTS',
  'resend attempts stop at the configured maximum');
select is((select attempt_count from private.registration_email_send_attempts where profile_id = tests.id('orphan')),
  2, 'a rejected attempt does not increment the attempt counter');

select is(has_table_privilege('anon', 'private.registration_email_send_attempts', 'SELECT'), false,
  'anon cannot inspect registration email attempts');
select is(has_table_privilege('authenticated', 'private.registration_email_send_attempts', 'SELECT'), false,
  'authenticated cannot inspect registration email attempts');
select is(has_function_privilege('anon',
  'public.claim_registration_email_confirmation(uuid,boolean,integer,integer)', 'execute'), false,
  'anon cannot claim confirmation sends');
select is(has_function_privilege('authenticated',
  'public.claim_registration_email_confirmation(uuid,boolean,integer,integer)', 'execute'), false,
  'authenticated cannot claim confirmation sends');
select is(has_function_privilege('service_role',
  'public.claim_registration_email_confirmation(uuid,boolean,integer,integer)', 'execute'), true,
  'only the service role can claim confirmation sends');

select * from finish();
rollback;
