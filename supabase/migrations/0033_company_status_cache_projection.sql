-- 0033: expose a safe company-verification projection on opportunity rows.
--
-- Company records themselves remain member/admin-only under RLS. Candidate clients must not need to
-- embed the private companies table just to filter cached opportunities, so the current verification
-- state is denormalized onto the already-public opportunity projection and maintained transactionally.

alter table public.opportunities
  add column if not exists company_verification_status text
  check (company_verification_status is null or company_verification_status in
    ('PENDING_REVIEW','VERIFIED','REJECTED','SUSPENDED'));

update public.opportunities o
   set company_verification_status = c.verification_status
  from public.companies c
 where c.id = o.company_id
   and o.company_verification_status is distinct from c.verification_status;

create or replace function private.sync_opportunity_company_verification_status()
returns trigger
language plpgsql security definer set search_path = ''
as $sync_opportunity_company_verification_status$
begin
  if new.company_id is null then
    new.company_verification_status := null;
  else
    select c.verification_status
      into new.company_verification_status
      from public.companies c
     where c.id = new.company_id;
  end if;
  return new;
end
$sync_opportunity_company_verification_status$;

revoke all on function private.sync_opportunity_company_verification_status()
  from public, anon, authenticated;

drop trigger if exists opportunity_company_verification_sync on public.opportunities;
create trigger opportunity_company_verification_sync
  before insert or update of company_id on public.opportunities
  for each row execute function private.sync_opportunity_company_verification_status();

-- Recreate the catalogue invalidation trigger including the denormalized company state.
drop trigger if exists opportunities_match_dirty on public.opportunities;
create trigger opportunities_match_dirty
  after insert or delete or update of title,description,location,attendance_mode,status,deadline,end_at,
    target_fields,registration_opens_at,capacity,registered_count,waitlist_enabled,company_verification_status
  on public.opportunities for each row execute function public.mark_all_recommendations_dirty();

-- Replace the company-state trigger body: sync all company-owned opportunity projections, invalidate the
-- catalogue cache, then bump profile snapshot versions to prevent a stale in-flight calculation winning.
create or replace function private.mark_company_recommendations_dirty()
returns trigger
language plpgsql security definer set search_path = ''
as $mark_company_recommendations_dirty_v2$
begin
  if new.verification_status is distinct from old.verification_status then
    update public.opportunities
       set company_verification_status = new.verification_status
     where company_id = new.id;

    update public.graduate_profiles
       set recommendations_dirty = true,
           profile_version = profile_version + 1,
           profile_updated_at = now();
  end if;
  return new;
end
$mark_company_recommendations_dirty_v2$;

revoke all on function private.mark_company_recommendations_dirty()
  from public, anon, authenticated;

comment on column public.opportunities.company_verification_status is
  'Safe denormalized company status for public opportunity reads; companies table remains member/admin RLS-scoped.';
