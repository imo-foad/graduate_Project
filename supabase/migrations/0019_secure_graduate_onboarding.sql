-- 0019: controlled graduate onboarding, privileged admin bootstrap and audited account lifecycle.
-- Public email/password sign-up stays disabled. Production accounts enter through admin invitations.

create or replace function private.is_platform_admin()
returns boolean
language sql stable security definer set search_path = ''
as $is_platform_admin$
  select auth.uid() is not null and exists (
    select 1
      from private.platform_admins a
      join public.profiles p on p.id = a.user_id
     where a.user_id = auth.uid()
       and a.is_active
       and p.account_status = 'ACTIVE'
  );
$is_platform_admin$;
revoke all on function private.is_platform_admin() from public, anon, authenticated;
grant execute on function private.is_platform_admin() to authenticated;

create or replace function private.is_active_account()
returns boolean
language sql stable security definer set search_path = ''
as $is_active_account$
  select auth.uid() is not null and exists (
    select 1 from public.profiles p
     where p.id = auth.uid() and p.account_status = 'ACTIVE'
  );
$is_active_account$;
revoke all on function private.is_active_account() from public, anon;
grant execute on function private.is_active_account() to authenticated;

-- Restrictive policies are layered on top of existing table-specific RLS policies.
-- This makes suspension effective for direct PostgREST reads/writes too, not only RPCs.
do $active_account_policies$
declare r record;
begin
  for r in
    select tablename from pg_tables
     where schemaname = 'public'
       and rowsecurity
  loop
    execute format(
      'create policy active_account_guard on public.%I as restrictive for all to authenticated using (private.is_active_account()) with check (private.is_active_account())',
      r.tablename
    );
  end loop;
end
$active_account_policies$;

-- Any RPC that uses _require_uid now rejects suspended/deleted accounts as well.
create or replace function public._require_uid()
returns uuid
language plpgsql stable security definer set search_path = ''
as $require_active_uid$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'PT401';
  end if;
  select p.account_status into v_status from public.profiles p where p.id = v_uid;
  if not found or v_status <> 'ACTIVE' then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode = 'PT403';
  end if;
  return v_uid;
end
$require_active_uid$;

create table private.platform_admin_audit (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id) on delete set null,
  target_user_id uuid,
  action text not null check (action in (
    'BOOTSTRAP_FIRST_ADMIN','ADMIN_GRANTED','ADMIN_REVOKED',
    'GRADUATE_INVITATION_CREATED','GRADUATE_INVITATION_SENT',
    'GRADUATE_INVITATION_FAILED','GRADUATE_INVITATION_ACCEPTED',
    'GRADUATE_SUSPENDED','GRADUATE_REACTIVATED',
    'ACCOUNT_DELETION_REQUESTED','ACCOUNT_DELETION_APPROVED',
    'ACCOUNT_DELETION_REJECTED','ACCOUNT_DELETED',
    'COMPANY_CREATOR_TRANSFERRED'
  )),
  reference_id uuid,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  occurred_at timestamptz not null default now()
);
create index platform_admin_audit_recent_idx
  on private.platform_admin_audit(occurred_at desc);
create index platform_admin_audit_target_idx
  on private.platform_admin_audit(target_user_id, occurred_at desc);

create table private.graduate_invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null check (
    email = lower(btrim(email))
    and length(email) between 6 and 254
    and email ~ '^[a-z0-9.!#$%&''*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$'
  ),
  full_name text not null check (length(btrim(full_name)) between 2 and 200),
  verification_note text not null check (length(btrim(verification_note)) between 10 and 2000),
  invited_by uuid references auth.users(id) on delete set null,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  status text not null default 'INVITING'
    check (status in ('INVITING','PENDING','ACCEPTED','FAILED','REVOKED')),
  failure_code text check (failure_code is null or failure_code in (
    'AUTH_INVITE_REJECTED','AUTH_INVITE_UNAVAILABLE','INVITATION_FINALIZATION_FAILED'
  )),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  accepted_at timestamptz
);
create unique index graduate_invitations_one_active_email
  on private.graduate_invitations(email)
  where status in ('INVITING','PENDING');
create index graduate_invitations_status_idx
  on private.graduate_invitations(status, created_at desc);

create table private.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  status text not null default 'REQUESTED'
    check (status in ('REQUESTED','APPROVED','DELETING','REJECTED','COMPLETED')),
  reason text check (reason is null or length(reason) <= 1000),
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  completed_at timestamptz
);
create unique index account_deletion_one_open_per_user
  on private.account_deletion_requests(user_id)
  where user_id is not null and status in ('REQUESTED','APPROVED','DELETING');
create index account_deletion_queue_idx
  on private.account_deletion_requests(status, requested_at);

alter table private.platform_admin_audit enable row level security;
alter table private.graduate_invitations enable row level security;
alter table private.account_deletion_requests enable row level security;
revoke all on private.platform_admin_audit, private.graduate_invitations,
  private.account_deletion_requests from public, anon, authenticated;
grant select, insert, update, delete on private.platform_admin_audit,
  private.graduate_invitations, private.account_deletion_requests to service_role;

create or replace function private.reject_platform_admin_audit_mutation()
returns trigger
language plpgsql set search_path = ''
as $reject_platform_admin_audit_mutation$
begin
  raise exception 'PLATFORM_ADMIN_AUDIT_IMMUTABLE' using errcode = 'PT403';
end
$reject_platform_admin_audit_mutation$;
revoke all on function private.reject_platform_admin_audit_mutation() from public, anon, authenticated;
create trigger platform_admin_audit_immutable
  before update or delete on private.platform_admin_audit
  for each row execute function private.reject_platform_admin_audit_mutation();

create or replace function public.assert_platform_admin()
returns boolean
language plpgsql stable security definer set search_path = ''
as $assert_platform_admin$
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  return true;
end
$assert_platform_admin$;
revoke all on function public.assert_platform_admin() from public, anon, authenticated;
grant execute on function public.assert_platform_admin() to authenticated;

create or replace function public.create_graduate_invitation(
  p_email text,
  p_full_name text,
  p_verification_note text
)
returns table (invitation_id uuid, status text)
language plpgsql security definer set search_path = ''
as $create_graduate_invitation$
declare
  v_actor uuid := public._require_uid();
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_name text := btrim(coalesce(p_full_name,''));
  v_note text := btrim(coalesce(p_verification_note,''));
  v_id uuid;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if length(v_name) not between 2 and 200
     or length(v_note) not between 10 and 2000
     or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$'
     or length(v_email) > 254 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_email, 0));
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'EMAIL_ALREADY_REGISTERED' using errcode = 'PT409';
  end if;

  insert into private.graduate_invitations(email, full_name, verification_note, invited_by)
  values (v_email, v_name, v_note, v_actor)
  returning id into v_id;

  insert into private.platform_admin_audit(actor_user_id, action, reference_id, details)
  values (v_actor, 'GRADUATE_INVITATION_CREATED', v_id,
          jsonb_build_object('email', v_email, 'verification_note_recorded', true));
  return query select v_id, 'INVITING'::text;
exception
  when unique_violation then
    raise exception 'INVITATION_ALREADY_ACTIVE' using errcode = 'PT409';
end
$create_graduate_invitation$;

create or replace function public.finalize_graduate_invitation(
  p_invitation_id uuid,
  p_auth_user_id uuid,
  p_success boolean,
  p_failure_code text default null
)
returns text
language plpgsql security definer set search_path = ''
as $finalize_graduate_invitation$
declare v_invite private.graduate_invitations;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_invitation_id is null or p_success is null
     or (p_success and p_auth_user_id is null)
     or (not p_success and p_failure_code not in (
       'AUTH_INVITE_REJECTED','AUTH_INVITE_UNAVAILABLE','INVITATION_FINALIZATION_FAILED'
     )) then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select * into v_invite from private.graduate_invitations
   where id = p_invitation_id for update;
  if not found then raise exception 'INVITATION_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_invite.status <> 'INVITING' then
    if p_success and v_invite.status in ('PENDING','ACCEPTED')
       and v_invite.auth_user_id = p_auth_user_id then
      return v_invite.status;
    end if;
    raise exception 'INVITATION_NOT_FINALIZABLE' using errcode = 'PT409';
  end if;

  if p_success then
    if not exists (
      select 1 from auth.users u
       where u.id = p_auth_user_id and lower(u.email) = v_invite.email
    ) then
      raise exception 'INVITATION_USER_MISMATCH' using errcode = 'PT403';
    end if;
    update private.graduate_invitations
       set auth_user_id = p_auth_user_id, status = 'PENDING',
           sent_at = now(), failure_code = null
     where id = p_invitation_id;
    insert into private.platform_admin_audit(actor_user_id, target_user_id, action, reference_id)
    values (v_invite.invited_by, p_auth_user_id, 'GRADUATE_INVITATION_SENT', p_invitation_id);
    return 'PENDING';
  end if;

  update private.graduate_invitations
     set status = 'FAILED', failure_code = p_failure_code
   where id = p_invitation_id;
  insert into private.platform_admin_audit(actor_user_id, action, reference_id, details)
  values (v_invite.invited_by, 'GRADUATE_INVITATION_FAILED', p_invitation_id,
          jsonb_build_object('failure_code', p_failure_code));
  return 'FAILED';
end
$finalize_graduate_invitation$;
revoke all on function public.finalize_graduate_invitation(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.finalize_graduate_invitation(uuid, uuid, boolean, text) to service_role;

create or replace function public.list_graduate_invitations(
  p_status text default 'ALL',
  p_limit integer default 50
)
returns table (
  invitation_id uuid, email text, full_name text, status text,
  invited_by uuid, auth_user_id uuid, created_at timestamptz, sent_at timestamptz,
  accepted_at timestamptz, failure_code text, verification_note text
)
language plpgsql stable security definer set search_path = ''
as $list_graduate_invitations$
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_status is null or p_status not in ('ALL','INVITING','PENDING','ACCEPTED','FAILED','REVOKED')
     or p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  return query
  select i.id, i.email, i.full_name, i.status, i.invited_by, i.auth_user_id,
         i.created_at, i.sent_at, i.accepted_at, i.failure_code, i.verification_note
    from private.graduate_invitations i
   where p_status = 'ALL' or i.status = p_status
   order by i.created_at desc limit p_limit;
end
$list_graduate_invitations$;

create or replace function private.mark_graduate_invitation_accepted()
returns trigger
language plpgsql security definer set search_path = ''
as $mark_graduate_invitation_accepted$
declare v_invite private.graduate_invitations;
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    update private.graduate_invitations
       set status = 'ACCEPTED', accepted_at = now()
     where auth_user_id = new.id and status = 'PENDING'
     returning * into v_invite;
    if found then
      insert into private.platform_admin_audit(target_user_id, action, reference_id)
      values (new.id, 'GRADUATE_INVITATION_ACCEPTED', v_invite.id);
    end if;
  end if;
  return new;
end
$mark_graduate_invitation_accepted$;
revoke all on function private.mark_graduate_invitation_accepted() from public, anon, authenticated;
create trigger auth_user_invitation_accepted
  after update of email_confirmed_at on auth.users
  for each row execute function private.mark_graduate_invitation_accepted();

create or replace function public.set_platform_admin_access(
  p_user_id uuid, p_is_active boolean, p_reason text
)
returns boolean
language plpgsql security definer set search_path = ''
as $set_platform_admin_access$
declare v_actor uuid := public._require_uid(); v_existing boolean;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_user_id is null or p_is_active is null
     or p_reason is null or length(btrim(p_reason)) not between 8 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('platform-admin-membership', 0));

  if p_is_active and not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
     where u.id = p_user_id and u.email_confirmed_at is not null
       and p.account_status = 'ACTIVE'
  ) then
    raise exception 'ADMIN_TARGET_NOT_VERIFIED' using errcode = 'PT422';
  end if;

  select is_active into v_existing from private.platform_admins
   where user_id = p_user_id for update;
  if not found and not p_is_active then
    raise exception 'ADMIN_MEMBERSHIP_NOT_FOUND' using errcode = 'PT404';
  end if;
  if p_is_active then
    insert into private.platform_admins(user_id, is_active)
    values (p_user_id, true)
    on conflict (user_id) do update set is_active = true;
    insert into private.platform_admin_audit(actor_user_id, target_user_id, action, details)
    values (v_actor, p_user_id, 'ADMIN_GRANTED', jsonb_build_object('reason', btrim(p_reason)));
  else
    if coalesce(v_existing,false) and (
      select count(*) from private.platform_admins a
      join public.profiles p on p.id = a.user_id
      where a.is_active and p.account_status = 'ACTIVE'
        and a.user_id <> p_user_id
    ) = 0 then
      raise exception 'LAST_ACTIVE_ADMIN' using errcode = 'PT409';
    end if;
    update private.platform_admins set is_active = false where user_id = p_user_id;
    insert into private.platform_admin_audit(actor_user_id, target_user_id, action, details)
    values (v_actor, p_user_id, 'ADMIN_REVOKED', jsonb_build_object('reason', btrim(p_reason)));
  end if;
  return true;
end
$set_platform_admin_access$;

create or replace function public.bootstrap_first_platform_admin(
  p_user_id uuid, p_operator_reference text
)
returns boolean
language plpgsql security definer set search_path = ''
as $bootstrap_first_platform_admin$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_user_id is null or p_operator_reference is null
     or length(btrim(p_operator_reference)) not between 8 and 500 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('platform-admin-membership', 0));
  if exists (
    select 1 from private.platform_admins a
    join public.profiles p on p.id = a.user_id
    where a.is_active and p.account_status = 'ACTIVE'
  ) then
    raise exception 'ADMIN_ALREADY_BOOTSTRAPPED' using errcode = 'PT409';
  end if;
  if not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = p_user_id and u.email_confirmed_at is not null
      and p.account_status = 'ACTIVE'
  ) then
    raise exception 'ADMIN_TARGET_NOT_VERIFIED' using errcode = 'PT422';
  end if;
  insert into private.platform_admins(user_id, is_active)
  values (p_user_id, true)
  on conflict (user_id) do update set is_active = true;
  insert into private.platform_admin_audit(target_user_id, action, reference_id, details)
  values (p_user_id, 'BOOTSTRAP_FIRST_ADMIN', p_user_id,
          jsonb_build_object('operator_reference', btrim(p_operator_reference)));
  return true;
end
$bootstrap_first_platform_admin$;
revoke all on function public.bootstrap_first_platform_admin(uuid, text) from public, anon, authenticated;
grant execute on function public.bootstrap_first_platform_admin(uuid, text) to service_role;

create or replace function public.set_graduate_account_status_for_admin(
  p_actor_id uuid, p_user_id uuid, p_status text, p_reason text
)
returns boolean
language plpgsql security definer set search_path = ''
as $set_graduate_account_status_for_admin$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  if p_actor_id is null or p_user_id is null
     or p_status is null or p_status not in ('ACTIVE','SUSPENDED')
     or p_reason is null or length(btrim(p_reason)) not between 8 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from private.platform_admins a
    join public.profiles p on p.id = a.user_id
    where a.user_id = p_actor_id and a.is_active and p.account_status = 'ACTIVE'
  ) then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'USER_NOT_FOUND' using errcode = 'PT404';
  end if;
  if exists (
    select 1 from private.platform_admins
     where user_id = p_user_id and is_active
  ) then
    raise exception 'REVOKE_ADMIN_BEFORE_ACCOUNT_CHANGE' using errcode = 'PT409';
  end if;
  update public.profiles set account_status = p_status where id = p_user_id;
  insert into private.platform_admin_audit(actor_user_id, target_user_id, action, details)
  values (
    p_actor_id, p_user_id,
    case when p_status = 'SUSPENDED' then 'GRADUATE_SUSPENDED' else 'GRADUATE_REACTIVATED' end,
    jsonb_build_object('reason', btrim(p_reason))
  );
  return true;
end
$set_graduate_account_status_for_admin$;
revoke all on function public.set_graduate_account_status_for_admin(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.set_graduate_account_status_for_admin(uuid, uuid, text, text)
  to service_role;

create or replace function public.request_account_deletion(p_reason text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $request_account_deletion$
declare v_uid uuid := public._require_uid(); v_id uuid;
begin
  if exists (select 1 from private.platform_admins where user_id = v_uid and is_active) then
    raise exception 'ADMIN_ACCOUNT_REQUIRES_MANUAL_TRANSFER' using errcode = 'PT409';
  end if;
  if p_reason is not null and length(p_reason) > 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  insert into private.account_deletion_requests(user_id, reason)
  values (v_uid, nullif(btrim(coalesce(p_reason,'')), ''))
  returning id into v_id;
  update public.profiles set account_status = 'SUSPENDED' where id = v_uid;
  insert into private.platform_admin_audit(actor_user_id, target_user_id, action, reference_id)
  values (v_uid, v_uid, 'ACCOUNT_DELETION_REQUESTED', v_id);
  return v_id;
exception
  when unique_violation then
    raise exception 'ACCOUNT_DELETION_ALREADY_OPEN' using errcode = 'PT409';
end
$request_account_deletion$;

create or replace function public.get_account_deletion_queue(
  p_status text default 'REQUESTED', p_limit integer default 50
)
returns table (
  request_id uuid, user_id uuid, email text, full_name text, reason text,
  status text, requested_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $get_account_deletion_queue$
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_status is null or p_status not in ('REQUESTED','APPROVED','DELETING','REJECTED','COMPLETED','ALL')
     or p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  return query
  select d.id, d.user_id, p.email, p.full_name, d.reason, d.status, d.requested_at
    from private.account_deletion_requests d
    left join public.profiles p on p.id = d.user_id
   where p_status = 'ALL' or d.status = p_status
   order by d.requested_at asc limit p_limit;
end
$get_account_deletion_queue$;

create or replace function public.review_account_deletion_request(
  p_request_id uuid, p_decision text, p_note text
)
returns text
language plpgsql security definer set search_path = ''
as $review_account_deletion_request$
declare v_actor uuid := public._require_uid(); v_request private.account_deletion_requests;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_request_id is null or p_decision is null or p_decision not in ('APPROVE','REJECT')
     or p_note is null or length(btrim(p_note)) not between 8 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  select * into v_request from private.account_deletion_requests
   where id = p_request_id for update;
  if not found then raise exception 'ACCOUNT_DELETION_REQUEST_NOT_FOUND' using errcode = 'PT404'; end if;
  if v_request.status <> 'REQUESTED' or v_request.user_id is null then
    raise exception 'ACCOUNT_DELETION_REQUEST_NOT_REVIEWABLE' using errcode = 'PT409';
  end if;
  if exists (
    select 1 from private.platform_admins
     where user_id = v_request.user_id and is_active
  ) then
    raise exception 'ADMIN_ACCOUNT_REQUIRES_MANUAL_TRANSFER' using errcode = 'PT409';
  end if;
  if p_decision = 'APPROVE' then
    update private.account_deletion_requests
       set status = 'APPROVED', reviewed_by = v_actor, reviewed_at = now(), review_note = btrim(p_note)
     where id = p_request_id;
  else
    update private.account_deletion_requests
       set status = 'REJECTED', reviewed_by = v_actor, reviewed_at = now(), review_note = btrim(p_note)
     where id = p_request_id;
    update public.profiles set account_status = 'ACTIVE' where id = v_request.user_id;
  end if;
  insert into private.platform_admin_audit(actor_user_id, target_user_id, action, reference_id, details)
  values (
    v_actor, v_request.user_id,
    case when p_decision = 'APPROVE' then 'ACCOUNT_DELETION_APPROVED' else 'ACCOUNT_DELETION_REJECTED' end,
    p_request_id, jsonb_build_object('note', btrim(p_note))
  );
  return case when p_decision = 'APPROVE' then 'APPROVED' else 'REJECTED' end;
end
$review_account_deletion_request$;

create or replace function public.get_approved_account_deletion(p_request_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $get_approved_account_deletion$
declare v_user_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  select user_id into v_user_id from private.account_deletion_requests
   where id = p_request_id and status = 'APPROVED' for update;
  if not found or v_user_id is null then
    raise exception 'APPROVED_ACCOUNT_DELETION_NOT_FOUND' using errcode = 'PT404';
  end if;
  if exists (select 1 from private.platform_admins where user_id = v_user_id and is_active) then
    raise exception 'ADMIN_ACCOUNT_REQUIRES_MANUAL_TRANSFER' using errcode = 'PT409';
  end if;
  if exists (select 1 from public.companies where created_by = v_user_id)
     or exists (select 1 from public.company_memberships where user_id = v_user_id and role = 'OWNER' and is_active) then
    raise exception 'COMPANY_OWNERSHIP_TRANSFER_REQUIRED' using errcode = 'PT409';
  end if;
  update private.account_deletion_requests
     set status = 'DELETING'
   where id = p_request_id and status = 'APPROVED';
  return v_user_id;
end
$get_approved_account_deletion$;
revoke all on function public.get_approved_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.get_approved_account_deletion(uuid) to service_role;

create or replace function public.release_account_deletion_claim(p_request_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $release_account_deletion_claim$
declare v_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = 'PT403';
  end if;
  update private.account_deletion_requests
     set status = 'APPROVED'
   where id = p_request_id and status = 'DELETING';
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end
$release_account_deletion_claim$;
revoke all on function public.release_account_deletion_claim(uuid) from public, anon, authenticated;
grant execute on function public.release_account_deletion_claim(uuid) to service_role;

create or replace function private.mark_account_deletion_completed()
returns trigger
language plpgsql security definer set search_path = ''
as $mark_account_deletion_completed$
begin
  update private.account_deletion_requests
     set user_id = null, status = 'COMPLETED', completed_at = now()
   where user_id = old.id and status = 'DELETING';
  if found then
    insert into private.platform_admin_audit(target_user_id, action)
    values (old.id, 'ACCOUNT_DELETED');
  end if;
  return old;
end
$mark_account_deletion_completed$;
revoke all on function private.mark_account_deletion_completed() from public, anon, authenticated;
create trigger auth_user_account_deletion_completed
  before delete on auth.users
  for each row execute function private.mark_account_deletion_completed();

-- Preserve company verification history when a user account is erased.
alter table public.company_verification_history alter column actor_user_id drop not null;
alter table public.company_verification_history
  drop constraint if exists company_verification_history_actor_user_id_fkey;
alter table public.company_verification_history
  add constraint company_verification_history_actor_user_id_fkey
  foreign key (actor_user_id) references auth.users(id) on delete set null;

create or replace function public.transfer_company_creator(
  p_company_id uuid, p_new_owner_id uuid, p_reason text
)
returns boolean
language plpgsql security definer set search_path = ''
as $transfer_company_creator$
declare v_actor uuid := public._require_uid(); v_company public.companies;
begin
  if not private.is_platform_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = 'PT403';
  end if;
  if p_company_id is null or p_new_owner_id is null
     or p_reason is null or length(btrim(p_reason)) not between 8 and 1000 then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;
  if not exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
     where p.id = p_new_owner_id and p.account_status = 'ACTIVE'
       and u.email_confirmed_at is not null
  ) then
    raise exception 'USER_NOT_FOUND' using errcode = 'PT404';
  end if;
  select * into v_company from public.companies where id = p_company_id for update;
  if not found then raise exception 'COMPANY_NOT_FOUND' using errcode = 'PT404'; end if;
  update public.company_memberships set is_active = false
   where company_id = p_company_id and role = 'OWNER';
  insert into public.company_memberships(company_id, user_id, role, is_active)
  values (p_company_id, p_new_owner_id, 'OWNER', true)
  on conflict (company_id, user_id) do update set role = 'OWNER', is_active = true;
  update public.companies set created_by = p_new_owner_id where id = p_company_id;
  insert into private.platform_admin_audit(actor_user_id, target_user_id, action, reference_id, details)
  values (v_actor, v_company.created_by, 'COMPANY_CREATOR_TRANSFERRED', p_company_id,
          jsonb_build_object('new_owner_id', p_new_owner_id, 'reason', btrim(p_reason)));
  return true;
end
$transfer_company_creator$;

revoke all on function public.create_graduate_invitation(text, text, text) from public, anon, authenticated;
revoke all on function public.list_graduate_invitations(text, integer) from public, anon, authenticated;
revoke all on function public.set_platform_admin_access(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon, authenticated;
revoke all on function public.get_account_deletion_queue(text, integer) from public, anon, authenticated;
revoke all on function public.review_account_deletion_request(uuid, text, text) from public, anon, authenticated;
revoke all on function public.transfer_company_creator(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.create_graduate_invitation(text, text, text),
  public.list_graduate_invitations(text, integer),
  public.set_platform_admin_access(uuid, boolean, text),
  public.request_account_deletion(text),
  public.get_account_deletion_queue(text, integer),
  public.review_account_deletion_request(uuid, text, text),
  public.transfer_company_creator(uuid, uuid, text)
to authenticated;
revoke all on function public.assert_platform_admin() from public, anon, authenticated;
grant execute on function public.assert_platform_admin() to authenticated;

comment on table private.graduate_invitations is
  'Private admin-initiated graduate invitations. Public Auth sign-up remains disabled; invitation acceptance is derived from Auth email confirmation.';
comment on table private.platform_admin_audit is
  'Append-only platform admin security audit log; UPDATE and DELETE are rejected by trigger.';
comment on table private.account_deletion_requests is
  'Graduate-requested, platform-admin-reviewed account deletion. Auth deletion is performed only by the service-role Edge Function after approval.';
