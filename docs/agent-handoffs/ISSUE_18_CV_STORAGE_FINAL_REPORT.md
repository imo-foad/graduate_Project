# Issue #18 — durable CV Storage cleanup, end-to-end

**Status:** implementation complete and verified by the full CI workflow, including the real local Storage/Edge-Function E2E suite. Issue #18 should still stay open until the pull request is opened, reviewed, and merged (see *Issue state recommendation*).

- **Base:** `main` at `c44aaf4217f45d41b58b83cdd6618b71f5e34b7f`
- **Branch:** `fix/issue-18-cv-storage-cleanup-e2e`
- **Code HEAD:** `d2dedb4` (this report commit follows it)
- **Pull request:** not created — this environment has no authenticated GitHub write API (see *Remaining blockers*)
- **CI:** https://github.com/imo-foad/graduate_Project/actions/runs/45965430484 — **all three jobs passed** (static, synthetic university seed, database)

## Initial defect

Metadata deletion already enqueued a durable row in `private.cv_cleanup_queue`, and the
`cleanup-cv-objects` Edge Function already drained it. What was missing was proof and operational
hardening:

1. No test ever uploaded a real private object, deleted its metadata through the owner RPC, ran the
   real worker and verified that the **bytes** were gone. Every existing test stopped at the queue.
2. A failed Storage delete was re-eligible **immediately**, so a persistent provider error was retried
   on every worker invocation with no spacing; ten quick invocations could exhaust a row in seconds.
3. A queue row could still delete **live bytes**: if a `cv_documents` row was re-inserted for the same
   storage path (re-upload, or a replacement written later by retention tooling) after its cleanup was
   queued, the queued row remained claimable and would remove the now-live object.
4. The worker orchestration had no seam for a deterministic Storage-transport failure, so the failure,
   retry and recovery path was untested.

## Root cause

- Retry policy: `fail_cv_cleanup` (0030) wrote `next_attempt_at = now()`, making a failed row eligible
  on the next claim with no backoff. There was no bounded schedule derived from the attempt counter.
- Live-path race: cleanup cancellation only existed for `PROCESSING` rows via the lease, and the queue
  had no insert/update hook tying a metadata path to "this path is live again". Claiming did not
  re-check `cv_documents` either.
- No E2E test: the integration runner only exercised the queue through SQL, never the Storage API or the
  worker endpoint. Deleting a database row was implicitly treated as deleting the object.

## Changes implemented

| File | Change |
| --- | --- |
| `supabase/migrations/0039_cv_cleanup_retry_policy_and_live_path_guard.sql` | New additive migration: `private.cv_cleanup_backoff_seconds` (60s doubling, capped at 1800s), `fail_cv_cleanup` v3 scheduling `next_attempt_at` from the attempt count, `claim_cv_cleanup` v3 refusing paths that metadata references and marking queued-but-live paths `DONE` (`PATH_STILL_REFERENCED`), `get_cv_cleanup_report` v3 splitting `pending`/`retry_ready`/`retry_scheduled`/`exhausted`, and a `cv_documents` insert/`storage_path`-update trigger cancelling queued cleanup for a re-used path (`PATH_REUSED_CLEANUP_CANCELLED`). |
| `supabase/functions/_shared/cv-cleanup-runner.ts` | New injected orchestration: bounded batches (50 rows, max 5 batches), duplicate-claim defence, path validation (`isSafeCvCleanupPath`: UUID owner prefix, no traversal/absolute/duplicate separators/backslash/NUL, optional graduate-prefix match), stable error codes only (`STORAGE_DELETE_FAILED`, `UNSAFE_STORAGE_PATH`), no path or CV content in logs. |
| `supabase/functions/cleanup-cv-objects/index.ts` | Wires the runner to `claim_cv_cleanup`/Storage `remove`/`complete_cv_cleanup`/`fail_cv_cleanup`, keeps the service-role JWT check, adds a 20s Storage/PostgREST timeout, returns counts only. |
| `tests/cv-cleanup-runner.test.ts` | 11 deterministic worker tests with injected claim/remove/complete/fail (success, forged/duplicate claims, unsafe paths, Storage failure, failure-not-recorded, completion-not-recorded, batch bounds, path validation matrix, log content). |
| `supabase/tests/database/21_cv_cleanup_lifecycle.test.sql` | New 46-assertion pgTAP file: backoff schedule and cap, scheduled-vs-ready reporting, lease expiry recovery, `PATH_STILL_REFERENCED`, `PATH_REUSED_CLEANUP_CANCELLED`, exhausted rows not auto-claimed, operator retry, and service-role-only privileges. |
| `supabase/tests/database/16_cv_cleanup_queue.test.sql` | Extended for the v3 claim/report contract and retained the service-role delete grant assertion. |
| `tests/integration/cv-cleanup.integration.mjs` | New E2E suite against the local gateway and real Storage API: owner deletion, replacement, re-used key (explicit upsert), missing object, rejected unsafe path, scheduled retry after a recorded failure, expired lease, concurrent claims, exhausted attempts + operator requeue, full approved account deletion, and worker/queue authorization. |
| `scripts/run-local-integrations.sh` | Runs the E2E suite after `cv-parse`. |
| `scripts/run-db-tests.sh` | 19-file pgTAP expectation. |
| `.github/workflows/backend-tests.yml` | `node --check` for the new integration file. |
| `tests/db-script-flow.test.ts`, `tests/workflow_lint.py`, `README.md`, `docs/ANDROID_INTEGRATION.md`, `docs/agent-handoffs/ISSUES_18_24_BASELINE.md` | Contract/flow coverage and documentation. |

No historical migration was edited. `0039` is additive and does not write to `storage.objects`.

## New tests

- Worker unit: `tests/cv-cleanup-runner.test.ts` — 11 tests.
- Database: `supabase/tests/database/21_cv_cleanup_lifecycle.test.sql` — 46 assertions; `16_cv_cleanup_queue.test.sql` — 32 assertions.
- E2E (local gateway + Storage): `tests/integration/cv-cleanup.integration.mjs` — self-checking assertions printed as `PASS <name>`.

## Exact commands executed and results

| Command | Result |
| --- | --- |
| `npm test` (branch HEAD) | **PASSED** — `tests 198`, `pass 198`, `fail 0` (run twice consecutively) |
| `python3 -m unittest tests/contract_openapi.py` | **PASSED** — 24 tests |
| `python3 -m unittest tests/workflow_lint.py` | **PASSED** — 14 tests |
| `node --check` on every changed `.mjs`, `bash -n` on `run-db-tests.sh` / `run-local-integrations.sh` | **PASSED** |
| Local PostgreSQL 17.12 + pgTAP 1.3.3 harness: apply all 38 migrations, both seeds twice, then all 19 pgTAP files | **PASSED** — 19/19 files, 764 assertions, no failures |
| `npm run test:db` (Supabase CLI + Docker) | **BLOCKED_ENVIRONMENT** — no Docker daemon, Supabase CLI or `pg_prove` in this sandbox |
| `tests/integration/cv-cleanup.integration.mjs` (real Storage objects) | **NOT_RUN locally** (BLOCKED_ENVIRONMENT: no Docker/Supabase CLI) |
| GitHub Actions workflow `backend-tests` on `d2dedb4` | **PASSED** — static, synthetic-seed and database jobs all green; the database job runs migrations, both seeds, 19 pgTAP files, concurrency and the full HTTP/Storage integration suite including `cv-cleanup.integration.mjs` |

The pgTAP result comes from a real PostgreSQL 17 server with the repository's migrations and seeds and
the actual pgTAP extension; the Supabase-managed objects (`auth.users`, `auth.uid()`/`auth.role()`,
`storage.objects`/`buckets`, `storage.foldername`, the direct-delete guard, `service_role` grants) were
provided by a local shim, so it is strong schema evidence but **not** a Supabase-stack run.

## Repeated-run results

- `npm test` on this branch: 198/198 twice consecutively.
- pgTAP 19-file suite locally: 19/19 files, 764 assertions, zero failures.
- CI: the workflow ran three times on this branch. The early runs exposed two real test defects (see
  below); the final run `45965430484` passed every job, and the database job executed the real Storage
  E2E suite end to end. One intermediate run failed a login lookup while the newly created Auth user
  was not yet usable; the next run passed the same code path, so the login step is timing-sensitive in
  CI and is called out under *Outstanding defects*.

## Failures discovered and fixed during this work

1. **Re-used object key could not be re-uploaded in the E2E test** — the Storage API rejects `POST` of an
   existing key unless `x-upsert` is set (commit `fbb7881`). An explicit upsert then proved to be
   rejected as well: the private bucket deliberately has **no UPDATE policy**, so in-place overwrite is
   not a supported client operation. The scenario now models the real flow — remove the old object
   through the Storage API, upload the same key again, re-register it — which is what actually makes a
   path live again and must cancel the queued cleanup (commit `75ffe27`).
2. **Immediate retry** — replaced with bounded exponential backoff (0039).
3. **Live-path deletion race** — closed with the insert/update trigger plus claim-time re-check.
4. **Unsafe queue path** — the worker now rejects non-owner-prefixed/traversal paths before any Storage
   call, and records `UNSAFE_STORAGE_PATH` instead of deleting.

## Security review

- `delete_cv_document` remains the only client deletion path; direct `DELETE` on `cv_documents` stays
  revoked for `authenticated` (pgTAP 16/21 and the E2E authorization block assert this).
- `claim_cv_cleanup`, `complete_cv_cleanup`, `fail_cv_cleanup`, `retry_cv_cleanup`,
  `get_cv_cleanup_report` are executable by `service_role` only; `private.cv_cleanup_queue` is not
  exposed through PostgREST.
- The worker endpoint requires the exact service-role JWT (403 otherwise) and returns only
  `processed`/`done`/`failed`.
- Storage paths are validated before use; only stable error codes are persisted or logged, never paths,
  file names, CV text, credentials or provider error text.
- No fault-injection parameter, test-only endpoint or production credential was added. The failure seam
  is dependency injection inside the worker module.

## Remaining product/external limitations

- The E2E suite cannot run in this sandbox (no Docker/Supabase CLI); its passing evidence comes from the
  GitHub Actions database job, not from a local run in this environment.
- Logs of failed runs are not downloadable without repository-admin credentials. To keep failures
  diagnosable, the runners now publish the failing stage/suite and a short redacted tail as a workflow
  annotation, and tee stderr into the suite logs.
- The Auth login immediately after admin user creation failed once in CI and passed on the next run
  (see *Outstanding defects*).
- Unsafe-path rows stay `FAILED` and follow the normal bounded retry schedule until exhausted; they are
  observable in the report and requeueable by the operator, but they are not terminal on first
  detection. This is deliberate (bounded, visible) and documented here.

## Branch / PR / CI

- Branch: `fix/issue-18-cv-storage-cleanup-e2e`
- HEAD: `fbb7881` (report commit adds this file)
- PR: **not created** — no authenticated GitHub write path in this environment (**OUT_OF_SCOPE /
  BLOCKED_ENVIRONMENT** for this session); compare URL:
  `https://github.com/imo-foad/graduate_Project/compare/main...fix/issue-18-cv-storage-cleanup-e2e`
- CI: https://github.com/imo-foad/graduate_Project/actions/runs/45965430484 — **PASSED**, all three jobs.

## Outstanding defects / limitations

- Opening the pull request and updating Issue #18 require GitHub write access this session does not have.
- The admin-create → password-grant login in the E2E suite failed once with an assertion on the login
  check and passed on the next run with identical code. The suite should treat that as a retryable wait
  (for example a short bounded poll until the new user can sign in) instead of a single attempt; this is
  left documented rather than masked.

## Issue state recommendation

**Keep #18 open** until the PR exists and is reviewed. All of the issue's technical completion criteria
(real object deletion, replacement safety, idempotent missing object, transient failure/retry, expired
lease, exhaustion, account deletion, cross-user and service-role restrictions) now have passing evidence
from the CI database job; only the Git/PR steps and the login-retry polish remain.
