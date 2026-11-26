-- 0031: recover the Auth-created/profile-pending gap in phone registration.
--
-- If the Edge Function process dies after Supabase Auth creates the phone account but before the
-- institution verification is recorded, a pending profile can exist without an identity ledger row.
-- The registration Edge Function calls this lookup only after a fresh successful institutional check.
-- The subsequent mandatory phone OTP still gates activation. An account with ANY prior verification
-- ledger row (including a different National-ID digest) is deliberately not eligible.

create or replace function public.find_unlinked_pending_registration_retry(
  p_phone text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_unlinked_pending_registration_retry$
declare
  v_profile_id uuid;
begin
  if p_phone is null or p_phone !~ '^\\+[1-9][0-9]{7,14}$' then
    raise exception 'INVALID_INPUT' using errcode = 'PT422';
  end if;

  select p.id
    into v_profile_id
    from public.profiles p
   where p.phone = p_phone
     and p.account_status = 'PENDING_VERIFICATION'
     and not exists (
       select 1
         from private.identity_verifications v
        where v.profile_id = p.id
     )
   limit 1
   for update of p;

  return v_profile_id;
end
$find_unlinked_pending_registration_retry$;

revoke all on function public.find_unlinked_pending_registration_retry(text)
  from public, anon, authenticated;
grant execute on function public.find_unlinked_pending_registration_retry(text)
  to service_role;

comment on function public.find_unlinked_pending_registration_retry(text) is
  'Service-role-only recovery lookup for a phone-auth account orphaned before any National-ID verification ledger row was written. Call only after a fresh successful institutional provider response.';
