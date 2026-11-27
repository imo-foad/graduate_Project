-- 0038: explicitly scope the intentional all-graduate recommendation invalidation.
--
-- Company verification changes affect whether a company's jobs may be recommended. Every
-- graduate's cached recommendations may therefore change. Supabase's PostgREST safe-update
-- guard rejects an UPDATE without a WHERE clause, so express the intentional all-row operation
-- using the graduate profile primary key's NOT NULL invariant.

create or replace function private.mark_company_recommendations_dirty()
returns trigger
language plpgsql security definer set search_path = ''
as $mark_company_recommendations_dirty_v3$
begin
  if new.verification_status is distinct from old.verification_status then
    update public.opportunities
       set company_verification_status = new.verification_status
     where company_id = new.id;

    update public.graduate_profiles
       set recommendations_dirty = true,
           profile_version = profile_version + 1,
           profile_updated_at = now()
     where profile_id is not null;
  end if;
  return new;
end
$mark_company_recommendations_dirty_v3$;

revoke all on function private.mark_company_recommendations_dirty()
  from public, anon, authenticated;

comment on function private.mark_company_recommendations_dirty() is
  'When company verification changes, refresh public listing status and invalidate every graduate recommendation cache using an explicit safe-update predicate.';
