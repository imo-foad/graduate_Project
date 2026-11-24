# Alumni Connect AI — Backend Audit Report

**Audit date:** 2026-11-24  
**Repository:** `imo-foad/graduate_Project` (private)  
**Review branch:** `fix/postgres-runtime-test-failures`  
**Pull request:** [#2 — PostgreSQL and Storage test fixes](https://github.com/imo-foad/graduate_Project/pull/2)

## Snapshot and safety

A full repository snapshot was created before the current audit on branch `backup/pre-full-audit-2026-11-24`. The snapshot points to commit `08d5af2f4ca6aefb03073c22bf2972793b647d5c`.

All corrective work is isolated on `fix/postgres-runtime-test-failures` and proposed through PR #2, which targets `backend-initial-import`. The `main` branch has not been changed. No Cloud Supabase project has been linked, reset, migrated, or otherwise modified.

## What the real CI run proved

GitHub Actions run [#17](https://github.com/imo-foad/graduate_Project/actions/runs/45402124871), at commit `08d5af2f4ca6aefb03073c22bf2972793b647d5c`, was the first successful start of the real local PostgreSQL/Supabase test stack for this repository.

The database job reached and completed the following stages:
- Docker and PostgreSQL client checks passed.
- Supabase CLI installed and verified.
- Migrations 0001–0008 applied.
- Catalogue seeds loaded and checked.
- All five pgTAP files executed: 203 assertions total.

The pgTAP result was **200 passing / 3 failing**. The failures were concrete:

1. **RLS recursion — tests 37 and 38 in `03_rls_security.test.sql`.** Saving an opportunity caused PostgreSQL error `42P17: infinite recursion detected in policy for relation "saved_opportunities"`. The catalogue SELECT policy queries `saved_opportunities`, while the saved-opportunity INSERT policy queried `opportunities`, creating a policy cycle.
2. **Storage test expectation — test 9 in `04_storage_cv_ownership.test.sql`.** The test expected SQLSTATE `P0001`; Supabase returned `42501` with the message that direct deletion from Storage tables is not allowed and the Storage API must be used. The test was asserting the wrong SQLSTATE.

The other pgTAP files, including RPC rules and recommendation-cache integrity, passed in that run. The concurrency phase did **not** execute because the runner stops after a failed pgTAP suite.

The static job in run #17 also failed one fake-runner test: its expected error still named migration 0007 even though the runner correctly stopped at the missing migration 0008. That test fixture has been updated to migration 0009.

## Corrections committed on the review branch

### Migration 0008 — safe text-array appends

File: `supabase/migrations/0008_fix_array_appends.sql`

- Replaced scalar text concatenation with `array_append()` in the final `eligibility_failures()` implementation.
- Replaced scalar text concatenation with `array_append()` in `get_my_insights()`.
- Preserved the existing function signatures and return contracts.
- Added static regression checks and an RPC test that exercises missing profile fields.

The prior real PostgreSQL run applied migration 0008, and the RPC/eligibility pgTAP file passed in that run.

### Migration 0009 — break saved-opportunity RLS recursion

File: `supabase/migrations/0009_fix_saved_opportunity_rls_recursion.sql`

- Added `public._opportunity_exists_for_saved_item(uuid)`, a SECURITY DEFINER helper with an empty search path.
- Replaced the recursive subquery in the `saved_insert` policy with that helper.
- Explicitly revoked default execution rights and granted execution only to `authenticated`.

This change is designed to preserve the existing rule that a graduate may save only an existing opportunity for their own account, without re-entering the catalogue RLS policy. It still needs a fresh real pgTAP run to confirm the fix.

### Storage test and runner

- Corrected the Storage direct-SQL delete assertion to expect SQLSTATE `42501`.
- Added an assertion that the `cv_objects_delete` policy is a DELETE policy scoped to the authenticated user's folder.
- Updated migration-count checks, fake runner fixtures, README, and audit documentation for migrations 0001–0009.

**Important Storage limitation:** The pgTAP test does not perform the delete through the HTTP Storage API. It verifies that direct SQL deletion is blocked and inspects the owner-folder policy. An API-level upload/delete test is still a separate verification item; do not interpret this pgTAP assertion as end-to-end proof that a user can delete their own object through the API.

## Remaining verification

The review branch must receive a fresh GitHub Actions run and pass all of these before the PR is considered ready:

- Static TypeScript tests.
- OpenAPI contract tests.
- Workflow/script lint tests.
- All nine migrations on the disposable local PostgreSQL stack.
- Seed idempotency and integrity checks.
- All five pgTAP files, including saved-opportunity RLS and Storage policy assertions.
- Real concurrent registration, application, and recommendation-cache tests.

Until the fresh run is green, the status is **FIXES PREPARED — RUNTIME RE-VERIFICATION PENDING**, not fully passed.

## Files and branches

- Snapshot: `backup/pre-full-audit-2026-11-24`
- Active fixes: `fix/postgres-runtime-test-failures`
- Review: [Pull request #2](https://github.com/imo-foad/graduate_Project/pull/2)
- Actions evidence: [Run #17](https://github.com/imo-foad/graduate_Project/actions/runs/45402124871)
