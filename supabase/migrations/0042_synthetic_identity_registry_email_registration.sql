-- 0042: local synthetic identity registry and email-confirmed registration (forward-only).
--
-- Demo-MVP product decision: email is the canonical Supabase Auth identifier; phone is optional
-- contact data. Registration no longer calls an external institutional provider and never requests
-- an SMS OTP. Instead it verifies the submitted synthetic identifier against a private, local
-- registry that is seeded only with clearly fake `SYNTH-...` identifiers.
--
-- This is NOT institutional verification. Every registry row and every resulting identity carries
-- the explicit `SYNTHETIC_SEED` marker. Real National IDs are rejected by the identifier format and
-- by the registry lookup; arbitrary identifiers are never accepted.

create extension if not exists pgcrypto with schema extensions;

alter table public.profiles add column if not exists email_verified_at timestamptz;

-- ---------------------------------------------------------------------------------------------------
-- 1. Private synthetic registry. No client role can read or write it; only the service role (used by
--    the register Edge Function) can resolve a keyed digest through the RPC below.
-- ---------------------------------------------------------------------------------------------------
create table if not exists private.synthetic_identity_registry (
  id uuid primary key default gen_random_uuid(),
  lookup_digest text not null check (lookup_digest ~ '^[0-9a-f]{64}$'),
  synthetic_ref_hint text not null check (synthetic_ref_hint ~ '^[A-Z0-9]{2,8}$'),
  display_name text not null check (length(btrim(display_name)) between 2 and 200),
  identity_type text not null check (identity_type in ('STUDENT','GRADUATE','FACULTY')),
  institution_ref text not null check (length(btrim(institution_ref)) between 1 and 120),
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object'),
  seed_marker text not null default 'SYNTHETIC_SEED' check (seed_marker = 'SYNTHETIC_SEED'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (lookup_digest, identity_type, institution_ref)
);
create index if not exists synthetic_identity_registry_lookup_idx
  on private.synthetic_identity_registry (lookup_digest)
  where is_active;

alter table private.synthetic_identity_registry enable row level security;
revoke all on private.synthetic_identity_registry from public, anon, authenticated;
grant select, insert, update, delete on private.synthetic_identity_registry to service_role;
-- Deliberately no RLS policy: the registry is never exposed through PostgREST, even to its owner.

-- Normalize the demo identifier. Only the `SYNTH-` namespace is accepted, so a real 14-digit
-- National ID can never be mistaken for a synthetic registry entry.
create or replace function private.normalize_synthetic_id(p_value text)
returns text language plpgsql immutable set search_path = ''
as $normalize_synthetic_id$
declare
  v_value text := upper(btrim(coalesce(p_value, '')));
begin
  if v_value = '' or length(v_value) > 48
     or v_value !~ '^SYNTH-[A-Z0-9]+(-[A-Z0-9]+)*$' then
    raise exception 'INVALID_SYNTHETIC_ID' using errcode = 'PT422';
  end if;
  return v_value;
end
$normalize_synthetic_id$;
revoke all on function private.normalize_synthetic_id(text) from public, anon, authenticated, service_role;

-- SHA-256 lookup digest. This is a synthetic demo identifier, not a real National ID; the value is
-- still never stored in plaintext. The Edge Function computes the same digest with WebCrypto.
create or replace function private.synthetic_identity_digest(p_synthetic_id text)
returns text language sql immutable set search_path = ''
as $synthetic_identity_digest$
  select encode(
    extensions.digest('alumni-connect:synthetic:v1:' || private.normalize_synthetic_id(p_synthetic_id), 'sha256'),
    'hex'
  );
$synthetic_identity_digest$;
revoke all on function private.synthetic_identity_digest(text) from public, anon, authenticated, service_role;

create or replace function private.set_synthetic_identity_registry_updated_at()
returns trigger language plpgsql set search_path = ''
as $set_synthetic_identity_registry_updated_at$
begin
  new.updated_at := now();
  return new;
end
$set_synthetic_identity_registry_updated_at$;
revoke all on function private.set_synthetic_identity_registry_updated_at() from public, anon, authenticated;
drop trigger if exists synthetic_identity_registry_updated_at on private.synthetic_identity_registry;
create trigger synthetic_identity_registry_updated_at
  before update on private.synthetic_identity_registry
  for each row execute function private.set_synthetic_identity_registry_updated_at();

-- Seed exactly the disposable demo cohort. The seed is idempotent: re-running the migration keeps
-- the same rows and does not create duplicates.
insert into private.synthetic_identity_registry (
  lookup_digest, synthetic_ref_hint, display_name, identity_type, institution_ref, attributes
) values
  (private.synthetic_identity_digest('SYNTH-STUDENT-0001'), '0001',
   'Sara Synthetic Student', 'STUDENT', 'SYNTH-STU-0001',
   '{"department":"Software Engineering","major":"Software Engineering","academic_track":"Software Engineering","academic_level":3,"gpa":3.50}'::jsonb),
  (private.synthetic_identity_digest('SYNTH-STUDENT-0002'), '0002',
   'Youssef Synthetic Student', 'STUDENT', 'SYNTH-STU-0002',
   '{"department":"Cybersecurity","major":"Cybersecurity","academic_track":"Cybersecurity","academic_level":4,"gpa":3.20}'::jsonb),
  (private.synthetic_identity_digest('SYNTH-GRADUATE-0001'), '0001',
   'Omar Synthetic Graduate', 'GRADUATE', 'SYNTH-GRAD-0001',
   '{"college":"Computers and Information"}'::jsonb),
  (private.synthetic_identity_digest('SYNTH-FACULTY-0001'), '0001',
   'Mona Synthetic Faculty', 'FACULTY', 'SYNTH-FAC-0001',
   '{"department":"Computer Science","specialization":"Distributed Systems","academic_title":"ASSOCIATE_PROFESSOR"}'::jsonb),
  (private.synthetic_identity_digest('SYNTH-MULTI-0001'), '0001',
   'Ali Synthetic Multi-Identity', 'GRADUATE', 'SYNTH-GRAD-0002',
   '{"college":"Computers and Information"}'::jsonb),
  (private.synthetic_identity_digest('SYNTH-MULTI-0001'), '0001',
   'Ali Synthetic Multi-Identity', 'FACULTY', 'SYNTH-FAC-0002',
   '{"department":"Computer Science","specialization":"Databases","academic_title":"LECTURER"}'::jsonb)
on conflict (lookup_digest, identity_type, institution_ref) do update
  set display_name = excluded.display_name,
      synthetic_ref_hint = excluded.synthetic_ref_hint,
      attributes = excluded.attributes,
      seed_marker = 'SYNTHETIC_SEED',
      is_active = true,
      updated_at = now();

-- Service-role-only resolver. Returns `{found:false}` for any unknown or inactive digest and never
-- echoes the submitted identifier.
create or replace function public.resolve_synthetic_identity(p_lookup_digest text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $resolve_synthetic_identity$
declare
  v_identities jsonb;
  v_display_name text;
begin
  if p_lookup_digest is null or p_lookup_digest !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select jsonb_agg(jsonb_build_object(
           'identity_type', r.identity_type,
           'institution_ref', r.institution_ref,
           'attributes', r.attributes
         ) order by r.identity_type),
         min(r.display_name)
    into v_identities, v_display_name
    from private.synthetic_identity_registry r
   where r.lookup_digest = p_lookup_digest
     and r.is_active
     and r.seed_marker = 'SYNTHETIC_SEED';

  if v_identities is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'source', 'SYNTHETIC_SEED',
    'display_name', v_display_name,
    'identities', v_identities
  );
end
$resolve_synthetic_identity$;
revoke all on function public.resolve_synthetic_identity(text) from public, anon, authenticated;
grant execute on function public.resolve_synthetic_identity(text) to service_role;
comment on function public.resolve_synthetic_identity(text) is
  'Service-role-only lookup in the private synthetic identity registry. Synthetic demo data only; never an institutional verification.';

comment on table private.synthetic_identity_registry is
  'Disposable synthetic demo identities for local development. Not real institutional data. No client access.';

-- ---------------------------------------------------------------------------------------------------
-- 2. Registration trigger: email-first accounts start PENDING until the email is confirmed and the
--    synthetic identity is associated. Legacy/demo/invitation accounts keep their existing behavior.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $handle_new_user_v4$
declare
  v_registration_flow text := new.raw_user_meta_data ->> 'registration_flow';
  v_email_registration boolean := coalesce(v_registration_flow = 'EMAIL_IDENTITY_VERIFICATION', false);
  v_contact_phone text;
begin
  v_contact_phone := case
    when v_email_registration then private.normalize_auth_phone(new.raw_user_meta_data ->> 'contact_phone')
    else private.normalize_auth_phone(new.phone)
  end;

  insert into public.profiles (id, full_name, email, phone, account_status)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 'مستخدم جديد'),
          new.email,
          v_contact_phone,
          case
            when new.email is null or v_email_registration then 'PENDING_VERIFICATION'
            else 'ACTIVE'
          end);

  -- A pending registration must not receive a graduate career profile before its verified
  -- identity is recorded. Legacy email/invitation accounts remain compatible.
  if new.email is not null and not v_email_registration then
    insert into public.graduate_profiles (profile_id) values (new.id);
  end if;
  return new;
end $handle_new_user_v4$;

-- ---------------------------------------------------------------------------------------------------
-- 3. Verification contract gains an explicit source. `SYNTHETIC_SEED` is never mixed with a real
--    provider result.
-- ---------------------------------------------------------------------------------------------------
drop function if exists public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb);

create or replace function public.record_identity_verification(
  p_profile_id uuid,
  p_provider text,
  p_provider_reference text,
  p_national_id_digest text,
  p_national_id_last4 text,
  p_identities jsonb,
  p_status text,
  p_error_code text default null,
  p_attributes jsonb default '{}'::jsonb,
  p_verification_source text default 'INSTITUTION_PROVIDER'
) returns jsonb
language plpgsql security definer set search_path = ''
as $record_identity_verification_v2$
declare
  v_existing private.identity_verifications;
  v_identity jsonb;
  v_type text;
  v_ref text;
  v_count integer := 0;
  v_id uuid;
  v_verification_id uuid;
begin
  if p_profile_id is null or not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'USER_NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_status is null or p_status not in ('VERIFIED','REJECTED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_national_id_digest is null or length(p_national_id_digest) < 32 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_provider is null or length(btrim(p_provider)) = 0 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if p_verification_source is null
     or p_verification_source not in ('INSTITUTION_PROVIDER','MANUAL_ADMIN','LEGACY_INVITATION','SYNTHETIC_SEED') then
    raise exception 'INVALID_VERIFICATION_SOURCE' using errcode = 'PT422';
  end if;

  select * into v_existing from private.identity_verifications
   where national_id_digest = p_national_id_digest for update;
  if found and v_existing.profile_id <> p_profile_id then
    raise exception 'IDENTITY_ALREADY_LINKED' using errcode = 'PT409';
  end if;

  insert into private.identity_verifications (
    profile_id, provider, provider_reference, national_id_digest, national_id_last4,
    status, error_code, attributes, verified_at)
  values (p_profile_id, btrim(p_provider), nullif(btrim(coalesce(p_provider_reference,'')), ''),
          p_national_id_digest, nullif(btrim(coalesce(p_national_id_last4,'')), ''),
          p_status, nullif(btrim(coalesce(p_error_code,'')), ''),
          coalesce(p_attributes, '{}'::jsonb),
          case when p_status = 'VERIFIED' then now() end)
  on conflict (national_id_digest) do update
    set provider = excluded.provider, provider_reference = excluded.provider_reference,
        national_id_last4 = excluded.national_id_last4, status = excluded.status,
        error_code = excluded.error_code, attributes = excluded.attributes,
        verified_at = excluded.verified_at
    where private.identity_verifications.profile_id = excluded.profile_id
  returning id into v_verification_id;
  if not found then
    raise exception 'IDENTITY_ALREADY_LINKED' using errcode = 'PT409';
  end if;

  if p_status = 'VERIFIED' then
    if p_identities is null or jsonb_typeof(p_identities) <> 'array' or jsonb_array_length(p_identities) = 0 then
      raise exception 'IDENTITY_WITHOUT_VERIFIED_ROLE' using errcode = 'PT422';
    end if;
    if jsonb_array_length(p_identities) > 5 then
      raise exception 'INVALID_INPUT' using errcode = 'PT422';
    end if;
    for v_identity in select * from jsonb_array_elements(p_identities) loop
      v_type := v_identity ->> 'identity_type';
      v_ref := nullif(btrim(coalesce(v_identity ->> 'institution_ref', '')), '');
      if v_type is null or v_type not in ('STUDENT','GRADUATE','FACULTY') or v_ref is null then
        raise exception 'INVALID_IDENTITY' using errcode = 'PT422';
      end if;
      insert into public.human_identities
        (profile_id, identity_type, institution_ref, status, verification_source, attributes, verified_at)
      values (p_profile_id, v_type, v_ref, 'VERIFIED', p_verification_source,
              coalesce(v_identity -> 'attributes', '{}'::jsonb), now())
      on conflict (profile_id, identity_type, institution_ref) do update
        set status = 'VERIFIED', verification_source = p_verification_source,
            attributes = excluded.attributes, verified_at = now()
      returning id into v_id;
      if v_type = 'GRADUATE' then
        insert into public.graduate_profiles (profile_id) values (p_profile_id)
        on conflict (profile_id) do nothing;
      end if;
      insert into private.identity_audit(profile_id, identity_id, action, provider, details)
      values (p_profile_id, v_id, 'IDENTITY_VERIFIED', btrim(p_provider),
              jsonb_build_object('identity_type', v_type, 'institution_ref', v_ref,
                                 'verification_source', p_verification_source));
      v_count := v_count + 1;
    end loop;
  else
    insert into private.identity_audit(profile_id, action, provider, details)
    values (p_profile_id, 'IDENTITY_REJECTED', btrim(p_provider),
            jsonb_build_object('error_code', coalesce(p_error_code, 'UNKNOWN'),
                               'verification_source', p_verification_source));
  end if;

  return jsonb_build_object('status', p_status, 'verified_identities', v_count,
                            'verification_source', p_verification_source);
end $record_identity_verification_v2$;

revoke all on function public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb,text)
  from public, anon, authenticated;
grant execute on function public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb,text)
  to service_role;

-- ---------------------------------------------------------------------------------------------------
-- 4. Email-confirmation completion. The account becomes ACTIVE only when Supabase Auth confirmed the
--    email AND at least one verified identity is associated. Phone is contact data, not a proof.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.finalize_registration()
returns jsonb language plpgsql security definer set search_path = '' as $finalize_registration_v3$
declare
  v_uid uuid := auth.uid();
  v_email_confirmed_at timestamptz;
  v_email text;
  v_identity_count integer;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED' using errcode = 'PT401'; end if;
  select u.email_confirmed_at, u.email into v_email_confirmed_at, v_email
    from auth.users u where u.id = v_uid;
  if not found then raise exception 'USER_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_email_confirmed_at is null then
    raise exception 'EMAIL_NOT_VERIFIED' using errcode = 'PT409';
  end if;
  select count(*)::int into v_identity_count
    from public.human_identities
   where profile_id = v_uid and status = 'VERIFIED';
  if v_identity_count = 0 then raise exception 'IDENTITY_NOT_VERIFIED' using errcode = 'PT409'; end if;
  update public.profiles
     set email = coalesce(email, v_email),
         email_verified_at = v_email_confirmed_at,
         account_status = 'ACTIVE'
   where id = v_uid;
  insert into private.identity_audit(profile_id, action, details)
  values (v_uid, 'REGISTRATION_COMPLETED',
          jsonb_build_object('verified_identities', v_identity_count,
                             'email_verified', true));
  return jsonb_build_object('account_status', 'ACTIVE',
                            'verified_identities', v_identity_count,
                            'email_verified_at', v_email_confirmed_at);
end $finalize_registration_v3$;
revoke all on function public.finalize_registration() from public, anon;
grant execute on function public.finalize_registration() to authenticated;
comment on function public.finalize_registration() is
  'Completes email-first registration after Supabase Auth email confirmation and a verified synthetic identity association.';

-- ---------------------------------------------------------------------------------------------------
-- 5. Idempotent retry lookups for the register Edge Function. Only the exact pending email + digest
--    pair may be resumed; active accounts and mismatched identities are never returned.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.find_pending_email_registration_retry(
  p_email text,
  p_lookup_digest text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_pending_email_registration_retry$
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
    join private.identity_verifications v
      on v.profile_id = p.id
     and v.status = 'VERIFIED'
   where lower(p.email) = v_email
     and p.account_status = 'PENDING_VERIFICATION'
     and v.national_id_digest = p_lookup_digest
   order by v.verified_at desc, v.created_at desc
   limit 1
   for update of p;

  return v_profile_id;
end
$find_pending_email_registration_retry$;
revoke all on function public.find_pending_email_registration_retry(text,text)
  from public, anon, authenticated;
grant execute on function public.find_pending_email_registration_retry(text,text)
  to service_role;
comment on function public.find_pending_email_registration_retry(text,text) is
  'Service-role-only idempotency lookup for resending the email confirmation to the same pending email/synthetic-digest pair.';

create or replace function public.find_unlinked_pending_email_registration_retry(
  p_email text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_unlinked_pending_email_registration_retry$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_profile_id uuid;
begin
  if v_email = '' or length(v_email) > 254
     or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select p.id
    into v_profile_id
    from public.profiles p
    join auth.users u on u.id = p.id
   where lower(p.email) = v_email
     and p.account_status = 'PENDING_VERIFICATION'
     and u.raw_user_meta_data ->> 'registration_flow' = 'EMAIL_IDENTITY_VERIFICATION'
     and not exists (
       select 1 from private.identity_verifications v where v.profile_id = p.id
     )
   limit 1
   for update of p;

  return v_profile_id;
end
$find_unlinked_pending_email_registration_retry$;
revoke all on function public.find_unlinked_pending_email_registration_retry(text)
  from public, anon, authenticated;
grant execute on function public.find_unlinked_pending_email_registration_retry(text)
  to service_role;
comment on function public.find_unlinked_pending_email_registration_retry(text) is
  'Service-role-only recovery lookup for an email registration account orphaned before its synthetic identity ledger row was written.';
