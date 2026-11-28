-- 0042: private synthetic identity registry, strict access, and deterministic lookup.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- ---- 1. The registry is private and carries the synthetic marker ---------------------------------
select is((select relrowsecurity from pg_class where oid = 'private.synthetic_identity_registry'::regclass), true,
  'the synthetic registry has RLS enabled');
select is((select count(*)::int from pg_policies
            where schemaname = 'private' and tablename = 'synthetic_identity_registry'), 0,
  'the synthetic registry has no client RLS policy');
select is(has_table_privilege('anon', 'private.synthetic_identity_registry', 'SELECT'), false,
  'anon cannot read the synthetic registry');
select is(has_table_privilege('authenticated', 'private.synthetic_identity_registry', 'SELECT'), false,
  'authenticated cannot read the synthetic registry');
select is(has_table_privilege('authenticated', 'private.synthetic_identity_registry', 'INSERT'), false,
  'authenticated cannot add registry entries');
select is(has_table_privilege('service_role', 'private.synthetic_identity_registry', 'SELECT'), true,
  'service_role can resolve registry entries');

select is(has_function_privilege('anon', 'public.resolve_synthetic_identity(text)', 'EXECUTE'), false,
  'anon cannot call the registry resolver');
select is(has_function_privilege('authenticated', 'public.resolve_synthetic_identity(text)', 'EXECUTE'), false,
  'authenticated cannot call the registry resolver');
select is(has_function_privilege('service_role', 'public.resolve_synthetic_identity(text)', 'EXECUTE'), true,
  'service_role can call the registry resolver');
select is(has_function_privilege('authenticated', 'private.normalize_synthetic_id(text)', 'EXECUTE'), false,
  'authenticated cannot call the private normalizer');
select is(has_function_privilege('authenticated', 'private.synthetic_identity_digest(text)', 'EXECUTE'), false,
  'authenticated cannot compute registry digests');

-- ---- 2. Seed contents: every approved identity type, all SYNTHETIC_SEED ---------------------------
select is((select count(*)::int from private.synthetic_identity_registry), 6,
  'the registry seeds six synthetic identity rows');
select is((select count(*)::int from private.synthetic_identity_registry where seed_marker <> 'SYNTHETIC_SEED'), 0,
  'every registry row is marked SYNTHETIC_SEED');
select is((select count(distinct identity_type)::int from private.synthetic_identity_registry), 3,
  'the registry covers STUDENT, GRADUATE and FACULTY');
select is((select count(*)::int from private.synthetic_identity_registry where lookup_digest !~ '^[0-9a-f]{64}$'), 0,
  'no registry row stores a plaintext identifier');

-- ---- 3. The SQL digest matches the TypeScript WebCrypto digest -------------------------------------
select is(private.synthetic_identity_digest('synth-student-0001'),
  'edfde02baa7e4430d1de0e5e046d37a6c18ff08abd0916f3220006d27ccbb04b',
  'the SQL digest matches the shared TypeScript namespace for SYNTH-STUDENT-0001');
select throws_ok($$ select private.normalize_synthetic_id('30001011234567') $$,
  'PT422', 'INVALID_SYNTHETIC_ID',
  'a real-looking 14-digit National ID is not a synthetic identifier');
select throws_ok($$ select private.normalize_synthetic_id('SYNTH-') $$,
  'PT422', 'INVALID_SYNTHETIC_ID',
  'an empty synthetic namespace is rejected');
select throws_ok($$ select public.resolve_synthetic_identity('not-a-digest') $$,
  'PT422', 'INVALID_INPUT',
  'the resolver rejects a malformed digest');

-- ---- 4. Known, unknown, multi-identity and inactive lookups ----------------------------------------
select is(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-STUDENT-0001')) ->> 'found', 'true',
  'a seeded synthetic student resolves');
select is(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-STUDENT-0001')) ->> 'source', 'SYNTHETIC_SEED',
  'the resolver reports the synthetic source');
select is(jsonb_array_length(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-STUDENT-0001')) -> 'identities'), 1,
  'a single-identity synthetic person resolves one identity');
select is(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-MULTI-0001')) ->> 'found', 'true',
  'a multi-identity synthetic person resolves');
select is(jsonb_array_length(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-MULTI-0001')) -> 'identities'), 2,
  'a multi-identity synthetic person resolves both roles');
select is(public.resolve_synthetic_identity(repeat('f', 64)) ->> 'found', 'false',
  'an unknown digest is not found');
select is(public.resolve_synthetic_identity(repeat('f', 64)) -> 'identities', null,
  'an unknown digest exposes no identities');

update private.synthetic_identity_registry
   set is_active = false
 where lookup_digest = private.synthetic_identity_digest('SYNTH-FACULTY-0001');
select is(public.resolve_synthetic_identity(
  private.synthetic_identity_digest('SYNTH-FACULTY-0001')) ->> 'found', 'false',
  'an inactive synthetic identity is not found');
update private.synthetic_identity_registry
   set is_active = true
 where lookup_digest = private.synthetic_identity_digest('SYNTH-FACULTY-0001');

-- ---- 5. The registry table itself is not exposed in the public schema ------------------------------
select is((select count(*)::int from information_schema.tables
            where table_schema = 'public' and table_name = 'synthetic_identity_registry'), 0,
  'the registry table is not in the public schema');

select * from finish();
rollback;
