-- 0010: keep the saved-opportunity RLS helper out of PostgREST's exposed public schema.
-- Migration 0009 fixed the policy recursion, but its public SECURITY DEFINER helper
-- was also executable as a public RPC. Keep the policy helper in the unexposed
-- private schema instead, while granting only the role needed to evaluate the policy.

drop policy if exists saved_insert on public.saved_opportunities;
drop function if exists public._opportunity_exists_for_saved_item(uuid);

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

create policy saved_insert on public.saved_opportunities
for insert to authenticated
with check (
  graduate_id = (select auth.uid())
  and private._opportunity_exists_for_saved_item(opportunity_id)
);
