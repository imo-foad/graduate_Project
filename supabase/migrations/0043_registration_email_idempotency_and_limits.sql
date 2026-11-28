-- 0043: bind orphaned pending accounts to their exact synthetic identity and rate-limit
-- explicit confirmation resends. The register endpoint remains idempotent on ordinary retries.
begin;

-- The digest is set by Auth Admin in app_metadata, which the authenticated user cannot edit.
-- Never recover a pre-ledger pending account using email address alone.
drop function if exists public.find_unlinked_pending_email_registration_retry(text);

create or replace function public.find_unlinked_pending_email_registration_retry(
  p_email text,
  p_lookup_digest text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_unlinked_pending_email_registration_retry_v2$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_profile_id uuid;
begin
  if v_email = '' or length(v_email) > 254
     or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$'
     or p_lookup_digest is null or p_lookup_digest !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select p.id
    into v_profile_id
    from public.profiles p
    join auth.users u on u.id = p.id
   where lower(p.email) = v_email
     and p.account_status = 'PENDING_VERIFICATION'
     and u.email_confirmed_at is null
     and u.raw_user_meta_data ->> 'registration_flow' = 'EMAIL_IDENTITY_VERIFICATION'
     and u.raw_app_meta_data ->> 'registration_synthetic_digest' = p_lookup_digest
     and not exists (
       select 1 from private.identity_verifications v where v.profile_id = p.id
     )
   limit 1
   for update of p;

  return v_profile_id;
end
$find_unlinked_pending_email_registration_retry_v2$;
revoke all on function public.find_unlinked_pending_email_registration_retry(text,text)
  from public, anon, authenticated;
grant execute on function public.find_unlinked_pending_email_registration_retry(text,text)
  to service_role;
comment on function public.find_unlinked_pending_email_registration_retry(text,text) is
  'Service-role-only recovery lookup requiring exact email and Auth-admin-owned synthetic identity digest; never recovers by email alone.';

-- One row per pending Auth user. The RPC serializes concurrent callers with a row lock so duplicate
-- client requests cannot create duplicate confirmation sends or bypass cooldown / attempt limits.
create table if not exists private.registration_email_send_attempts (
  profile_id uuid primary key references auth.users(id) on delete cascade,
  attempt_count integer not null default 1 check (attempt_count between 1 and 5),
  last_attempt_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table private.registration_email_send_attempts enable row level security;
revoke all on private.registration_email_send_attempts from public, anon, authenticated, service_role;

create or replace function public.claim_registration_email_confirmation(
  p_profile_id uuid,
  p_explicit_resend boolean default false,
  p_cooldown_seconds integer default 60,
  p_max_attempts integer default 5
) returns jsonb
language plpgsql security definer set search_path = ''
as $claim_registration_email_confirmation$
declare
  v_account_status text;
  v_email_confirmed_at timestamptz;
  v_registration_flow text;
  v_attempt_count integer;
  v_last_attempt_at timestamptz;
  v_now timestamptz := clock_timestamp();
  v_retry_after integer;
  v_inserted boolean := false;
begin
  if p_profile_id is null
     or p_cooldown_seconds is null or p_cooldown_seconds < 1 or p_cooldown_seconds > 86400
     or p_max_attempts is null or p_max_attempts < 1 or p_max_attempts > 5 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select p.account_status, u.email_confirmed_at,
         u.raw_user_meta_data ->> 'registration_flow'
    into v_account_status, v_email_confirmed_at, v_registration_flow
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.id = p_profile_id;

  if not found or v_registration_flow <> 'EMAIL_IDENTITY_VERIFICATION' then
    raise exception 'PENDING_REGISTRATION_NOT_FOUND' using errcode = 'PT404';
  end if;

  if v_email_confirmed_at is not null or v_account_status <> 'PENDING_VERIFICATION' then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'ALREADY_CONFIRMED',
      'attempt_count', 0,
      'attempts_remaining', 0,
      'retry_after_seconds', 0
    );
  end if;

  insert into private.registration_email_send_attempts(profile_id, attempt_count, last_attempt_at)
  values (p_profile_id, 1, v_now)
  on conflict (profile_id) do nothing
  returning true into v_inserted;

  if coalesce(v_inserted, false) then
    return jsonb_build_object(
      'allowed', true,
      'reason', 'FIRST_REQUEST',
      'attempt_count', 1,
      'attempts_remaining', greatest(p_max_attempts - 1, 0),
      'retry_after_seconds', p_cooldown_seconds
    );
  end if;

  select a.attempt_count, a.last_attempt_at
    into v_attempt_count, v_last_attempt_at
    from private.registration_email_send_attempts a
   where a.profile_id = p_profile_id
   for update;

  v_retry_after := greatest(0, ceil(extract(epoch from
    (v_last_attempt_at + make_interval(secs => p_cooldown_seconds) - v_now)))::integer);

  if not coalesce(p_explicit_resend, false) then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'ALREADY_REQUESTED',
      'attempt_count', v_attempt_count,
      'attempts_remaining', greatest(p_max_attempts - v_attempt_count, 0),
      'retry_after_seconds', v_retry_after
    );
  end if;

  if v_attempt_count >= p_max_attempts then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'MAX_ATTEMPTS',
      'attempt_count', v_attempt_count,
      'attempts_remaining', 0,
      'retry_after_seconds', 0
    );
  end if;

  if v_retry_after > 0 then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'COOLDOWN',
      'attempt_count', v_attempt_count,
      'attempts_remaining', greatest(p_max_attempts - v_attempt_count, 0),
      'retry_after_seconds', v_retry_after
    );
  end if;

  update private.registration_email_send_attempts
     set attempt_count = v_attempt_count + 1,
         last_attempt_at = v_now,
         updated_at = v_now
   where profile_id = p_profile_id;

  return jsonb_build_object(
    'allowed', true,
    'reason', 'RESEND',
    'attempt_count', v_attempt_count + 1,
    'attempts_remaining', greatest(p_max_attempts - v_attempt_count - 1, 0),
    'retry_after_seconds', p_cooldown_seconds
  );
end
$claim_registration_email_confirmation$;

revoke all on function public.claim_registration_email_confirmation(uuid,boolean,integer,integer)
  from public, anon, authenticated;
grant execute on function public.claim_registration_email_confirmation(uuid,boolean,integer,integer)
  to service_role;
comment on function public.claim_registration_email_confirmation(uuid,boolean,integer,integer) is
  'Atomically claims a confirmation-email attempt for a pending email-first registration; ordinary registration retries never resend, explicit resends enforce cooldown and a five-attempt maximum.';

commit;
