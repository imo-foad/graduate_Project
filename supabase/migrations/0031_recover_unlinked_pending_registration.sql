-- 0031: recover an Auth-created profile left pending before the identity ledger write.
--
-- Call this lookup only after a fresh successful institutional verification in the register Edge Function.
-- It never returns an active profile or any pending profile that already has an identity verification row.
create or replace function public.find_unlinked_pending_registration_retry(
  p_phone text
) returns uuid
language plpgsql security definer set search_path = ''
as $find_unlinked_pending_registration_retry$
declare
  v_profile_id uuid;
begin
  if p_phone is null or p_phone !~ '^[+][1-9][0-9]{7,14}$' then
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
