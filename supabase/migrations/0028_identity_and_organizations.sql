-- 0028: identity, registration and organization hardening.
--
-- Product decisions (docs/PRODUCT_DECISIONS.md):
--   * registration requires National ID + phone + password, an institutional identity check and a phone OTP;
--   * login is phone + password only; the National ID is never a credential and is never stored in plaintext;
--   * one human account may hold several verified identities (STUDENT, GRADUATE, FACULTY);
--   * companies remain separate identities; publishing requires a VERIFIED company and OWNER/RECRUITER;
--   * a user can never grant themselves a role.
--
-- This migration is forward-only. It adds the account/identity model and tightens existing organization
-- functions. The institutional provider and SMS delivery are external dependencies; the adapter and the
-- mock are in TypeScript, and the real integration is recorded as BLOCKED_EXTERNAL in docs/.

-- ---------------------------------------------------------------------------------------------------
-- 1. Phone-first account model. Legacy/demo accounts keep their email; new accounts are phone-only and
--    start PENDING_VERIFICATION until both OTP and institutional identity are confirmed.
-- ---------------------------------------------------------------------------------------------------
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists phone_verified_at timestamptz;
alter table public.profiles alter column email drop not null;
alter table public.profiles drop constraint if exists profiles_phone_format_check;
alter table public.profiles add constraint profiles_phone_format_check
  check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$');
create unique index if not exists profiles_phone_key on public.profiles (phone) where phone is not null;
alter table public.profiles drop constraint if exists profiles_account_status_check;
alter table public.profiles add constraint profiles_account_status_check
  check (account_status in ('PENDING_VERIFICATION','ACTIVE','SUSPENDED'));

-- Phone-only Auth users have no email. Never fabricate one from the phone or National ID.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $handle_new_user_v2$
begin
  insert into public.profiles (id, full_name, email, phone, account_status)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 'مستخدم جديد'),
          new.email,
          nullif(btrim(new.phone), ''),
          case when new.email is null then 'PENDING_VERIFICATION' else 'ACTIVE' end);
  insert into public.graduate_profiles (profile_id) values (new.id);
  return new;
end $handle_new_user_v2$;

-- ---------------------------------------------------------------------------------------------------
-- 2. Multiple verified human identities per account.
-- ---------------------------------------------------------------------------------------------------
create table if not exists public.human_identities (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  identity_type text not null check (identity_type in ('STUDENT','GRADUATE','FACULTY')),
  institution_ref text not null check (length(btrim(institution_ref)) between 1 and 120),
  status text not null default 'PENDING' check (status in ('PENDING','VERIFIED','REVOKED')),
  verification_source text not null default 'INSTITUTION_PROVIDER'
    check (verification_source in ('INSTITUTION_PROVIDER','MANUAL_ADMIN','LEGACY_INVITATION')),
  attributes jsonb not null default '{}'::jsonb,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, identity_type, institution_ref)
);
create index if not exists human_identities_profile_idx on public.human_identities (profile_id, status);
alter table public.human_identities enable row level security;
revoke all on public.human_identities from public, anon, authenticated;
grant select on public.human_identities to authenticated;
grant select, insert, update, delete on public.human_identities to service_role;
create policy human_identities_select_own on public.human_identities for select to authenticated
  using (profile_id = (select auth.uid()));
-- No client INSERT/UPDATE/DELETE grant or policy: identities are written only by the service-role
-- verification contract, never by user-supplied role strings.

create or replace function public.set_human_identity_updated_at() returns trigger
language plpgsql set search_path = '' as $set_human_identity_updated_at$
begin new.updated_at := now(); return new; end $set_human_identity_updated_at$;
revoke all on function public.set_human_identity_updated_at() from public, anon, authenticated;
drop trigger if exists human_identities_updated_at on public.human_identities;
create trigger human_identities_updated_at before update on public.human_identities
  for each row execute function public.set_human_identity_updated_at();

-- ---------------------------------------------------------------------------------------------------
-- 3. National-ID verification ledger. Only a keyed digest is stored, never the raw identifier.
--    The unique digest prevents one institutional person from being linked to two accounts.
-- ---------------------------------------------------------------------------------------------------
create table if not exists private.identity_verifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  provider text not null check (length(btrim(provider)) between 1 and 120),
  provider_reference text,
  national_id_digest text not null unique check (length(national_id_digest) between 32 and 256),
  national_id_last4 text check (national_id_last4 is null or national_id_last4 ~ '^[0-9]{4}$'),
  status text not null check (status in ('VERIFIED','REJECTED')),
  error_code text,
  attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  verified_at timestamptz
);
create index if not exists identity_verifications_profile_idx on private.identity_verifications (profile_id);
alter table private.identity_verifications enable row level security;
revoke all on private.identity_verifications from public, anon, authenticated;
grant select, insert, update on private.identity_verifications to service_role;

create table if not exists private.identity_audit (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid,
  identity_id uuid,
  action text not null,
  actor_user_id uuid,
  provider text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table private.identity_audit enable row level security;
revoke all on private.identity_audit from public, anon, authenticated;
grant select, insert on private.identity_audit to service_role;

create or replace function private.reject_identity_audit_mutation() returns trigger
language plpgsql set search_path = '' as $reject_identity_audit_mutation$
begin
  raise exception 'IDENTITY_AUDIT_APPEND_ONLY' using errcode = 'PT422';
end $reject_identity_audit_mutation$;
revoke all on function private.reject_identity_audit_mutation() from public, anon, authenticated;
drop trigger if exists identity_audit_append_only on private.identity_audit;
create trigger identity_audit_append_only before update or delete on private.identity_audit
  for each row execute function private.reject_identity_audit_mutation();

-- ---------------------------------------------------------------------------------------------------
-- 4. Service-role verification contract used by the identity Edge Function.
--    p_identities: [{"identity_type":"STUDENT","institution_ref":"...","attributes":{...}}, ...]
--    The Edge Function validates the provider response and computes the keyed digest; SQL enforces the
--    unique-person rule and records the outcome atomically.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.record_identity_verification(
  p_profile_id uuid,
  p_provider text,
  p_provider_reference text,
  p_national_id_digest text,
  p_national_id_last4 text,
  p_identities jsonb,
  p_status text,
  p_error_code text default null,
  p_attributes jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $record_identity_verification$
declare
  v_existing private.identity_verifications;
  v_identity jsonb;
  v_type text;
  v_ref text;
  v_count integer := 0;
  v_id uuid;
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
        verified_at = excluded.verified_at;

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
      values (p_profile_id, v_type, v_ref, 'VERIFIED', 'INSTITUTION_PROVIDER',
              coalesce(v_identity -> 'attributes', '{}'::jsonb), now())
      on conflict (profile_id, identity_type, institution_ref) do update
        set status = 'VERIFIED', verification_source = 'INSTITUTION_PROVIDER',
            attributes = excluded.attributes, verified_at = now()
      returning id into v_id;
      insert into private.identity_audit(profile_id, identity_id, action, provider, details)
      values (p_profile_id, v_id, 'IDENTITY_VERIFIED', btrim(p_provider),
              jsonb_build_object('identity_type', v_type, 'institution_ref', v_ref));
      v_count := v_count + 1;
    end loop;
  else
    insert into private.identity_audit(profile_id, action, provider, details)
    values (p_profile_id, 'IDENTITY_REJECTED', btrim(p_provider),
            jsonb_build_object('error_code', coalesce(p_error_code, 'UNKNOWN')));
  end if;

  return jsonb_build_object('status', p_status, 'verified_identities', v_count);
end $record_identity_verification$;

revoke all on function public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.record_identity_verification(uuid,text,text,text,text,jsonb,text,text,jsonb)
  to service_role;

-- ---------------------------------------------------------------------------------------------------
-- 5. Phone/OTP completion. The account becomes ACTIVE only when Supabase Auth has confirmed the phone
--    AND an institutional identity is verified. Pending accounts are blocked by _require_uid and the
--    restrictive RLS guard from 0019 until then.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.finalize_registration()
returns jsonb language plpgsql security definer set search_path = '' as $finalize_registration$
declare
  v_uid uuid := auth.uid(); v_phone timestamptz; v_identity_count integer; v_phone_number text;
begin
  if v_uid is null then raise exception 'UNAUTHENTICATED' using errcode = 'PT401'; end if;
  select u.phone_confirmed_at, u.phone into v_phone, v_phone_number
    from auth.users u where u.id = v_uid;
  if not found then raise exception 'USER_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_phone is null then raise exception 'PHONE_NOT_VERIFIED' using errcode = 'PT409'; end if;
  select count(*)::int into v_identity_count
    from public.human_identities
   where profile_id = v_uid and status = 'VERIFIED';
  if v_identity_count = 0 then raise exception 'IDENTITY_NOT_VERIFIED' using errcode = 'PT409'; end if;
  update public.profiles
     set phone_verified_at = v_phone,
         phone = coalesce(phone, v_phone_number),
         account_status = 'ACTIVE'
   where id = v_uid;
  insert into private.identity_audit(profile_id, action, details)
  values (v_uid, 'REGISTRATION_COMPLETED',
          jsonb_build_object('verified_identities', v_identity_count));
  return jsonb_build_object('account_status', 'ACTIVE', 'verified_identities', v_identity_count);
end $finalize_registration$;
revoke all on function public.finalize_registration() from public, anon;
grant execute on function public.finalize_registration() to authenticated;
comment on function public.finalize_registration() is
  'Completes phone-first registration after Supabase Auth phone confirmation and an institutional identity verification.';

-- Own identities (read-only; includes PENDING/REVOKED history).
create or replace function public.list_my_identities()
returns table (id uuid, identity_type text, institution_ref text, status text, verification_source text,
               verified_at timestamptz, attributes jsonb)
language sql stable security definer set search_path = '' as $list_my_identities$
  select h.id, h.identity_type, h.institution_ref, h.status, h.verification_source, h.verified_at, h.attributes
    from public.human_identities h
   where h.profile_id = auth.uid()
   order by h.created_at;
$list_my_identities$;
revoke all on function public.list_my_identities() from public, anon;
grant execute on function public.list_my_identities() to authenticated;

-- Platform-admin manual identity review (e.g. when the institutional provider is unavailable).
create or replace function public.review_human_identity(
  p_identity_id uuid, p_decision text, p_note text default null
) returns jsonb language plpgsql security definer set search_path = '' as $review_human_identity$
declare v_actor uuid := public._require_uid(); h public.human_identities;
begin
  if not private.is_platform_admin() then raise exception 'ADMIN_REQUIRED' using errcode = 'PT403'; end if;
  if p_decision is null or p_decision not in ('VERIFIED','REVOKED') then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into h from public.human_identities where id = p_identity_id for update;
  if not found then raise exception 'IDENTITY_NOT_FOUND' using errcode = 'PT404'; end if;
  update public.human_identities
     set status = p_decision,
         verification_source = 'MANUAL_ADMIN',
         verified_at = case when p_decision = 'VERIFIED' then now() else verified_at end
   where id = h.id;
  insert into private.identity_audit(profile_id, identity_id, action, actor_user_id, details)
  values (h.profile_id, h.id, 'IDENTITY_' || p_decision, v_actor,
          jsonb_build_object('note', left(coalesce(btrim(p_note), ''), 500)));
  return jsonb_build_object('id', h.id, 'status', p_decision);
end $review_human_identity$;
revoke all on function public.review_human_identity(uuid, text, text) from public, anon, authenticated;
grant execute on function public.review_human_identity(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- 6. Organization hardening: admin-assisted membership changes, owner-initiated ownership transfer,
--    append-only role audit. VIEWER stays read-only because every write path requires OWNER/RECRUITER.
-- ---------------------------------------------------------------------------------------------------
create table if not exists private.company_role_audit (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  actor_user_id uuid,
  target_user_id uuid,
  action text not null,
  old_role text,
  new_role text,
  created_at timestamptz not null default now()
);
alter table private.company_role_audit enable row level security;
revoke all on private.company_role_audit from public, anon, authenticated;
grant select, insert on private.company_role_audit to service_role;

create or replace function public.set_company_member(
  p_company_id uuid, p_user_id uuid, p_role text, p_is_active boolean default true
) returns public.company_memberships
language plpgsql security definer set search_path = '' as $set_company_member_v2$
declare
  v_uid uuid := public._require_uid();
  m public.company_memberships;
  v_old_role text;
  v_admin boolean := private.is_platform_admin();
begin
  if not v_admin and not private.is_company_member(p_company_id, array['OWNER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  if p_user_id is null or p_user_id = v_uid
     or p_role is null or p_role not in ('RECRUITER','VIEWER')
     or p_is_active is null then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'USER_NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_is_active and exists (
       select 1 from public.company_memberships
       where company_id = p_company_id and user_id = p_user_id and role = 'OWNER'
     ) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select role into v_old_role from public.company_memberships
   where company_id = p_company_id and user_id = p_user_id;
  if p_is_active then
    insert into public.company_memberships(company_id, user_id, role, is_active)
    values (p_company_id, p_user_id, p_role, true)
    on conflict (company_id, user_id) do update
      set role = excluded.role, is_active = true
    returning * into m;
  else
    update public.company_memberships
       set is_active = false
     where company_id = p_company_id and user_id = p_user_id
       and role <> 'OWNER'
    returning * into m;
    if not found then raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'PT404'; end if;
  end if;
  insert into private.company_role_audit(company_id, actor_user_id, target_user_id, action, old_role, new_role)
  values (p_company_id, v_uid, p_user_id,
          case when p_is_active then 'MEMBERSHIP_UPSERTED' else 'MEMBERSHIP_DEACTIVATED' end,
          v_old_role, case when p_is_active then p_role else null end);
  return m;
end $set_company_member_v2$;
revoke all on function public.set_company_member(uuid, uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.set_company_member(uuid, uuid, text, boolean) to authenticated;

create or replace function public.transfer_company_ownership(
  p_company_id uuid, p_new_owner_id uuid
) returns public.company_memberships
language plpgsql security definer set search_path = '' as $transfer_company_ownership$
declare
  v_uid uuid := public._require_uid();
  v_old_owner uuid;
  m public.company_memberships;
  v_admin boolean := private.is_platform_admin();
begin
  if p_company_id is null or p_new_owner_id is null or p_new_owner_id = v_uid then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not v_admin and not private.is_company_member(p_company_id, array['OWNER']::text[]) then
    raise exception 'NOT_COMPANY_MEMBER' using errcode = 'PT403';
  end if;
  perform 1 from public.companies where id = p_company_id for update;
  if not found then raise exception 'COMPANY_NOT_FOUND' using errcode = 'PT404'; end if;
  if not exists (
    select 1 from public.company_memberships
     where company_id = p_company_id and user_id = p_new_owner_id and is_active
       and role in ('RECRUITER','VIEWER')
  ) then
    raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'PT404';
  end if;
  select user_id into v_old_owner from public.company_memberships
   where company_id = p_company_id and role = 'OWNER' and is_active;
  update public.company_memberships set role = 'RECRUITER'
   where company_id = p_company_id and role = 'OWNER' and is_active;
  update public.company_memberships set role = 'OWNER', is_active = true
   where company_id = p_company_id and user_id = p_new_owner_id
  returning * into m;
  update public.companies set created_by = p_new_owner_id where id = p_company_id;
  insert into private.company_role_audit(company_id, actor_user_id, target_user_id, action, old_role, new_role)
  values (p_company_id, v_uid, p_new_owner_id, 'OWNERSHIP_TRANSFERRED', 'MEMBER', 'OWNER');
  insert into private.identity_audit(profile_id, action, actor_user_id, details)
  values (v_old_owner, 'COMPANY_OWNERSHIP_TRANSFERRED', v_uid,
          jsonb_build_object('company_id', p_company_id, 'new_owner_id', p_new_owner_id));
  return m;
end $transfer_company_ownership$;
revoke all on function public.transfer_company_ownership(uuid, uuid) from public, anon, authenticated;
grant execute on function public.transfer_company_ownership(uuid, uuid) to authenticated;

comment on table public.human_identities is
  'Verified institutional affiliations attached to one human account. Multiple rows per profile are allowed; clients can only read their own.';
comment on table private.identity_verifications is
  'National-ID verification ledger. Only a keyed deterministic digest is stored, never the raw identifier. Service role only.';
comment on function public.transfer_company_ownership(uuid, uuid) is
  'Active company OWNER (or platform admin) transfers ownership to an existing active member; the previous owner becomes RECRUITER.';
