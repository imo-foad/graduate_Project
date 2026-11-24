-- 0010: reassert the private RLS helper and remove any legacy public helper.
-- Fresh installs now create the private helper in 0009. This migration also safely
-- cleans up databases that had applied the earlier public-helper form of 0009.

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
