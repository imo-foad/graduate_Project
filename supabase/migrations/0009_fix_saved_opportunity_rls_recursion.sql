-- 0009: remove saved-opportunity / catalogue RLS recursion without exposing an RPC.
-- The old saved_insert policy queried public.opportunities while opp_select queried
-- public.saved_opportunities. This SECURITY DEFINER helper bypasses catalogue RLS
-- for the existence check, but lives in the private (non-PostgREST-exposed) schema.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create or replace function private._opportunity_exists_for_saved_item(p_opportunity_id uuid)
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

revoke all on function private._opportunity_exists_for_saved_item(uuid) from public, anon, authenticated;
grant execute on function private._opportunity_exists_for_saved_item(uuid) to authenticated;

drop policy if exists saved_insert on public.saved_opportunities;
create policy saved_insert on public.saved_opportunities
for insert to authenticated
with check (
  graduate_id = (select auth.uid())
  and private._opportunity_exists_for_saved_item(opportunity_id)
);
