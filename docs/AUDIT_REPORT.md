# Alumni Connect AI — Full Repository Test & Audit

**Audit date:** 2026-11-24  
**Repository:** `imo-foad/graduate_Project` (private)  
**Review branch:** `fix/postgres-runtime-test-failures`  
**Pull request:** [#2 — PostgreSQL and Storage test fixes](https://github.com/imo-foad/graduate_Project/pull/2)

## Snapshot and scope

The pre-audit snapshot is preserved on `backup/pre-full-audit-2026-11-24` at `08d5af2f4ca6aefb03073c22bf2972793b647d5c` (51 tracked files). The active audit covers the complete 51-file repository tree: configuration, workflows, docs/OpenAPI, JSON fixtures, scripts, Edge Function source, SQL migrations and seeds, pgTAP tests, TypeScript tests, Python contract checks and concurrency scripts.

The audit and fixes remain on `fix/postgres-runtime-test-failures`. PR #2 targets `backend-initial-import`; `main` has not been changed. No Cloud Supabase project has been linked, reset, migrated or modified.

## Confirmed runtime findings

GitHub Actions run [#17](https://github.com/imo-foad/graduate_Project/actions/runs/45402124871) applied migrations 0001–0008, loaded the catalogue seeds, and ran all five pgTAP files (203 assertions). It reported 200 pass / 3 fail:

1. RLS recursion in saved-opportunity insertion (two tests): SQLSTATE `42P17`, because `saved_insert` queried opportunities while the opportunities SELECT policy queried saved opportunities.
2. Storage test expectation (one test): the test expected `P0001`, while Supabase's Storage protection returned `42501` for direct SQL deletion.

The runner stopped after pgTAP, so the concurrency suite did not execute in that run.

The same run found an outdated fake-runner assertion that still expected migration 0007 while the runner was checking migration 0008. That test fixture was subsequently updated.

## Fixes on the review branch

### Migration 0008 — safe text-array appends

`supabase/migrations/0008_fix_array_appends.sql` replaces scalar concatenation with `array_append()` in the final `eligibility_failures()` and `get_my_insights()` definitions. It preserves the function signatures and return values. The previous real PostgreSQL run applied migration 0008, and the RPC/eligibility pgTAP file passed in that run.

### Migration 0009 — RLS recursion fix

`supabase/migrations/0009_fix_saved_opportunity_rls_recursion.sql` introduced a SECURITY DEFINER existence helper to break the recursive policy dependency while preserving the ownership predicate. The policy fix itself needs a fresh pgTAP run to confirm it.

### Migration 0010 — hide the RLS helper from the public API

The full static contract review found a follow-on security concern in migration 0009: its helper was in `public` and had EXECUTE granted to `authenticated`, making it a callable public-schema function rather than only an internal RLS implementation detail.

`supabase/migrations/0010_hide_saved_item_helper_from_api.sql` moves the helper to the `private` schema, which is not included in `supabase/config.toml`'s PostgREST exposed schemas. It revokes default privileges, grants the minimum schema/function access needed by authenticated RLS evaluation, drops the public helper, and recreates `saved_insert` against the private helper.

### Storage and CI regressions

- Storage test now expects the observed `42501` direct-SQL protection response and checks the owner-folder DELETE policy.
- Migration-count, fake-runner, SQL-static, API-contract and documentation checks are updated for migrations 0001–0010.
- The Storage pgTAP assertion is not an HTTP Storage API end-to-end test. It does not yet prove upload-then-delete through the Storage API.

## Static review notes

- `fixtures/skills.json`: 50 unique skill IDs.
- `fixtures/opportunities.json`: 29 unique opportunity seed keys across 8 types.
- `fixtures/demo-profiles.json`: 4 demo profiles with unique emails.
- The deterministic scoring implementation explicitly documents six assumptions (B1–B6); its lexical similarity is a proxy, not an embedding model. These are product/quality limitations, not unreported runtime failures.
- Demo-user provisioning requires the operator to set the target URL and server-side credentials correctly; the script prints its destination before issuing Auth Admin requests.
- Supabase CLI is configured as `latest` in CI rather than a pinned version; this is a reproducibility risk.
- README's stated Node engine minimum and `package.json` engine minimum differ; CI currently uses Node 22 and the recorded runner used Node 22.23.5.

## Verification status

Run #17 is historical evidence for migrations 0001–0008 only. It is **not** evidence that migrations 0009 or 0010 pass. The latest source changes must pass a fresh GitHub Actions run covering:

- all Node/TypeScript tests;
- all OpenAPI contract tests;
- workflow and migration-count lint;
- all ten migrations on disposable local PostgreSQL;
- seed generation, idempotency, counts and referential integrity;
- all five pgTAP files;
- concurrency tests for registrations, applications and recommendation snapshot/cache races.

Until the fresh workflow is green, the overall status remains **IN PROGRESS — latest runtime verification pending**.

## Branches

- Snapshot: `backup/pre-full-audit-2026-11-24`
- Active review branch: `fix/postgres-runtime-test-failures`
- Review PR: [#2](https://github.com/imo-foad/graduate_Project/pull/2)
- Historical runtime evidence: [Actions run #17](https://github.com/imo-foad/graduate_Project/actions/runs/45402124871)
