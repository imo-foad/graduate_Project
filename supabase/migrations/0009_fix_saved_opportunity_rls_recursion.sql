-- 0009: remove the saved-opportunity / catalogue RLS recursion.
-- saved_insert previously queried opportunities, while opp_select queried saved_opportunities.
-- This SECURITY DEFINER predicate checks existence without re-entering opportunities RLS.
create or replace function public._opportunity_exists_for_saved_item(p_opportunity_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and exists (
       select 1
         from public.opportunities o
        where o.id = p_opportunity_id
     );
$$;

revoke all on function public._opportunity_exists_for_saved_item(uuid) from public, anon, authenticated;
grant execute on function public._opportunity_exists_for_saved_item(uuid) to authenticated;

drop policy if exists saved_insert on public.saved_opportunities;
create policy saved_insert on public.saved_opportunities
for insert to authenticated
with check (
  graduate_id = (select auth.uid())
  and public._opportunity_exists_for_saved_item(opportunity_id)
);
