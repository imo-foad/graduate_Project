# Issue #18 — durable CV Storage cleanup, end-to-end

**Status:** implementation complete and verified by the full CI workflow, including the real local Storage/Edge-Function E2E suite. Issue #18 should still stay open until the pull request is opened, reviewed, and merged (see *Issue state recommendation*).

- **Base:** `main`, merged into the branch in `ea24954`
- **Branch:** `fix/issue-18-cv-storage-cleanup-e2e`
- **Code HEAD:** `2ac737e` (this report commit follows it)
- **Pull request:** not created — this environment has no authenticated GitHub write API (see *Remaining blockers*)
- **CI:** https://github.com/imo-foad/graduate_Project/actions/runs/46031636686 — **all three jobs passed** on `2ac737e` (static, database, synthetic university seed)

## Initial defect

Metadata deletion already enqueued a durable row in `private.cv_cleanup_queue`, and the
`cleanup-cv-objects` Edge Function already drained it. What was missing was proof and operational
hardening:

1. No test ever uploaded a real private object, deleted its metadata through the owner RPC, ran the
   real worker and verified that the **bytes** were gone. Every existing test stopped at the queue.
2. A failed Storage delete was re-eligible **immediately**, so a persistent provider error was retried
   on every worker invocation with no spacing; ten quick invocations could exhaust a row in seconds.
3. A queue row could still delete **live bytes**: re-registering a storage path whose cleanup was already
   queued (re-upload, or a replacement written later by retention tooling) either cancelled the queued
   row or left it claimable depending on its status, so the worker could delete bytes that had just
   become live. The policy is now the opposite: a path that entered the ledger is retired for good.
4. The worker orchestration had no seam for a deterministic Storage-transport failure, so the failure,
   retry and recovery path was untested.

## Root cause

- Retry policy: `fail_cv_cleanup` (0030) wrote `next_attempt_at = now()`, making a failed row eligible
  on the next claim with no backoff. There was no bounded schedule derived from the attempt counter.
- Live-path race: `0039` cancelled a queued row only while it was `PENDING`/`FAILED`, so the path could
  be re-registered while its row was `PROCESSING` — the worker may already be deleting exactly those
  bytes — and nothing serialized the metadata write against the queue insert. A claim-time re-check
  shrank the window but could not close it, because the worker decides after the claim. Re-using a key
  is not a supported client flow anyway (the private bucket has no UPDATE policy), so retiring the path
  costs nothing a real user needs.
- No E2E test: the integration runner only exercised the queue through SQL, never the Storage API or the
  worker endpoint. Deleting a database row was implicitly treated as deleting the object.

## Changes implemented

| File | Change |
| --- | --- |
| `supabase/migrations/0039_cv_cleanup_retry_policy_and_live_path_guard.sql` | New additive migration: `private.cv_cleanup_backoff_seconds` (60s doubling, capped at 1800s), `fail_cv_cleanup` v3 scheduling `next_attempt_at` from the attempt count, `claim_cv_cleanup` v3 refusing paths that metadata references and marking queued-but-live paths `DONE` (`PATH_STILL_REFERENCED`), `get_cv_cleanup_report` v3 splitting `pending`/`retry_ready`/`retry_scheduled`/`exhausted`. Retained as history: its re-use cancellation trigger (`PATH_REUSED_CLEANUP_CANCELLED`, `PENDING`/`FAILED` only) is dropped by `0040`. |
| `supabase/migrations/0040_cv_storage_path_retirement_and_locking.sql` | New additive migration that makes Storage paths immutable once retired: a fail-closed preflight refuses a deployment whose live metadata already overlaps a ledger path, `private.lock_cv_storage_paths(text[])` takes transaction-scoped advisory locks (hashed per exact path, acquired in deterministic order), `private.guard_cv_document_storage_path()` rejects any insert/path-update to a path with a ledger row **regardless of status** (`CV_STORAGE_PATH_RETIRED`) and locks deletes until commit, `private.guard_cv_cleanup_queue_insert()` serializes the reverse direction and refuses to enqueue a live path (`CV_STORAGE_PATH_LIVE`), and a queue tombstone's `storage_path` can never be changed (`CV_CLEANUP_STORAGE_PATH_IMMUTABLE`). It drops the `0039` trigger/function. |
| `supabase/functions/_shared/cv-cleanup-runner.ts` | New injected orchestration: bounded batches (50 rows, max 5 batches), duplicate-claim defence, path validation (`isSafeCvCleanupPath`: UUID owner prefix, no traversal/absolute/duplicate separators/backslash/NUL, optional graduate-prefix match), stable error codes only (`STORAGE_DELETE_FAILED`, `UNSAFE_STORAGE_PATH`), no path or CV content in logs. |
| `supabase/functions/cleanup-cv-objects/index.ts` | Wires the runner to `claim_cv_cleanup`/Storage `remove`/`complete_cv_cleanup`/`fail_cv_cleanup`, keeps the service-role JWT check, adds a 20s Storage/PostgREST timeout, returns counts only. |
| `tests/cv-cleanup-runner.test.ts` | 11 deterministic worker tests with injected claim/remove/complete/fail (success, forged/duplicate claims, unsafe paths, Storage failure, failure-not-recorded, completion-not-recorded, batch bounds, path validation matrix, log content). |
| `supabase/tests/database/21_cv_cleanup_lifecycle.test.sql` | 60-assertion pgTAP file: backoff schedule and cap, scheduled-vs-ready reporting, lease expiry recovery, the retired-path matrix (`PENDING`/`PROCESSING`/`FAILED`/`DONE` all unregistrable, one permanent tombstone row, no registration from a path update, replacement on a fresh key still claimable), lease recovery keeping the tombstone, an unchallengeable queue tombstone path, the legacy `PATH_STILL_REFERENCED` claim guard, exhausted rows not auto-claimed, operator retry, and service-role-only privileges. |
| `supabase/tests/database/16_cv_cleanup_queue.test.sql` | Extended for the v3 claim/report contract and retained the service-role delete grant assertion. |
| `tests/integration/cv-cleanup.integration.mjs` | E2E suite against the local gateway and real Storage API: owner deletion, replacement on a fresh key, **a retired key rejected while its row is `PENDING` and again while it is a `DONE` tombstone** (the real worker still deletes the original bytes), missing object, rejected unsafe path, scheduled retry after a recorded failure, expired lease, concurrent claims, exhausted attempts + operator requeue, full approved account deletion, and worker/queue authorization. The disposable account is created with `targetPassword` and signed in with the same value. |
| `scripts/run-local-integrations.sh` | Runs the E2E suite after `cv-parse`. |
| `tests/db/cv-cleanup-concurrency.sh` | Deterministic two-session proof of the advisory-lock protocol: no sleeps, sessions stop at an advisory-lock barrier that is released only after the blocked session is observed in `pg_stat_activity`; delete-first proves the blocked registration waits for the deletion's commit and is then rejected with `CV_STORAGE_PATH_RETIRED`, insert-first proves the duplicate is rejected by `storage_path` uniqueness and the deletion still succeeds. Never leaves a live-metadata/queue overlap behind. |
| `scripts/run-db-tests.sh` | 19-file pgTAP expectation, the immutable-path race stage (`E2`) with a failure diagnostic that names `bash tests/db/cv-cleanup-concurrency.sh`, and its log/summary wiring. |
| `.github/workflows/backend-tests.yml` | `node --check` for the new integration file. |
| `tests/db-script-flow.test.ts`, `tests/workflow_lint.py`, `README.md`, `docs/ANDROID_INTEGRATION.md`, `docs/agent-handoffs/ISSUES_18_24_BASELINE.md` | Contract/flow coverage and documentation. |

No historical migration was edited. `0039` and `0040` are additive, and neither writes to `storage.objects`:
the private bucket's bytes are still deleted only by the worker through the Storage API.

## New tests

- Worker unit: `tests/cv-cleanup-runner.test.ts` — 11 tests.
- Database: `supabase/tests/database/21_cv_cleanup_lifecycle.test.sql` — 60 assertions; `16_cv_cleanup_queue.test.sql` — 32 assertions.
- Concurrency (real sessions): `tests/db/cv-cleanup-concurrency.sh` — 12 checks across both orderings.
- E2E (local gateway + Storage): `tests/integration/cv-cleanup.integration.mjs` — self-checking assertions printed as `PASS <name>`.

## Exact commands executed and results

| Command | Result |
| --- | --- |
| `npm test` (branch HEAD) | **PASSED** — `tests 222`, `pass 222`, `fail 0` |
| `npm run test:contract` | **PASSED** — 24 tests |
| `npm run test:workflow` | **PASSED** — 16 tests |
| `node --check` on every changed `.mjs`, `bash -n` on `run-db-tests.sh` / `run-local-integrations.sh` / both concurrency scripts | **PASSED** |
| Local PostgreSQL 17.12 + pgTAP 1.3.3 harness: apply all 39 migrations, both seeds twice, then all 19 pgTAP files | **PASSED** — 19/19 files, 778 assertions, no failures (`21_cv_cleanup_lifecycle` alone: 60) |
| `DB_URL=… bash tests/db/concurrency.sh` (real two-session races) | **PASSED** — `ALL CONCURRENCY CHECKS PASSED` |
| `DB_URL=… bash tests/db/cv-cleanup-concurrency.sh` (barrier-based retired-path race) | **PASSED** — `CV CLEANUP CONCURRENCY PASSED`, 12 checks |
| `npm run test:db` (Supabase CLI + Docker) | **BLOCKED_ENVIRONMENT** — no Docker daemon or Supabase CLI in this sandbox |
| `tests/integration/cv-cleanup.integration.mjs` (real Storage objects) | **NOT_RUN locally** (BLOCKED_ENVIRONMENT: no Docker/Supabase CLI); executed by the CI database job |
| GitHub Actions run `46031636686` on `2ac737e` | **PASSED** — `Static tests, OpenAPI contract and workflow lint`, `Database tests (local stack only, fails on any error)` and the synthetic-seed job all `success` |

The pgTAP result comes from a real PostgreSQL 17 server with the repository's migrations and seeds and
the actual pgTAP extension; the Supabase-managed objects (`auth.users`, `auth.uid()`/`auth.role()`,
`storage.objects`/`buckets`, `storage.foldername`, the direct-delete guard, `service_role` grants) were
provided by a local shim, so it is strong schema evidence but **not** a Supabase-stack run.

## Repeated-run results

- `npm test` on this branch: 222/222 green after the runner fix; the tree before that fix failed only
  `immutable CV Storage path race failure fails the database runner` (item 6 below).
- pgTAP 19-file suite locally: 19/19 files, 778 assertions, zero failures.
- `tests/db/concurrency.sh` and `tests/db/cv-cleanup-concurrency.sh` locally: both passed against the
  same PostgreSQL 17 instance, in both race orderings, with the blocked session observed while waiting.
- CI on this branch: run `46004844108` (`fd93fe3`) failed the static job on item 6; run `46031636686`
  (`2ac737e`) passed all three jobs, and the database job ran migrations, both seeds, all 19 pgTAP
  files, both concurrency suites and the Storage E2E — including the retired-path scenario and the
  account-creation password flow.

## Failures discovered and fixed during this work

1. **Re-used object key deleted live bytes** — `0039` treated re-use as a supported flow and cancelled
   only `PENDING`/`FAILED` cleanup, leaving the `PROCESSING` window open. The private bucket has no
   UPDATE policy either, so in-place overwrite was never a real client operation. `0040` now retires
   the path instead, and the E2E proves rejection in both a queued and a tombstoned state while the
   real worker still deletes the original bytes and a replacement uses a fresh key (`ea24954`).
2. **Immediate retry** — replaced with bounded exponential backoff (0039).
3. **Live-path deletion race** — closed by retiring the path under an advisory-lock protocol shared by
   metadata registration, metadata deletion and queue insertion (`0040`), instead of cancelling cleanup.
4. **Unsafe queue path** — the worker now rejects non-owner-prefixed/traversal paths before any Storage
   call, and records `UNSAFE_STORAGE_PATH` instead of deleting.
5. **The E2E account was created with one password and signed in with another** — after the admin
   create call the suite logged in with the fixture password, which failed intermittently in CI. It now
   creates the account with `targetPassword` and signs in with that same value, and asserts the returned
   user id is the one it created.
6. **The runner never named the failing immutable-path stage** — the stage ran under `set -e`, so a
   failure aborted without the diagnostic that names `bash tests/db/cv-cleanup-concurrency.sh`; the
   control-flow test that pins it (and therefore the static-tests job) failed on `fd93fe3`. The stage is
   now guarded explicitly and reported through `fail` (`2ac737e`).

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
- Unsafe-path rows stay `FAILED` and follow the normal bounded retry schedule until exhausted; they are
  observable in the report and requeueable by the operator, but they are not terminal on first
  detection. This is deliberate (bounded, visible) and documented here.

## Branch / PR / CI

- Branch: `fix/issue-18-cv-storage-cleanup-e2e`
- HEAD: `2ac737e` (report commit adds this file)
- PR: **not created** — no authenticated GitHub write path in this environment (**OUT_OF_SCOPE /
  BLOCKED_ENVIRONMENT** for this session); compare URL:
  `https://github.com/imo-foad/graduate_Project/compare/main...fix/issue-18-cv-storage-cleanup-e2e`
- CI: https://github.com/imo-foad/graduate_Project/actions/runs/46031636686 — **PASSED**, all three jobs
  (static, database, synthetic seed).

## Outstanding defects / limitations

- Opening the pull request and updating Issue #18 require GitHub write access this session does not have.
- Database-job logs are not downloadable without repository-admin credentials, so that job's evidence is
  its green `Database tests` step plus the workflow annotation the runners emit when a stage fails.

## Issue state recommendation

**Keep #18 open** until the PR exists and is reviewed. All of the issue's technical completion criteria
(real object deletion, immutable retired paths in every queue state, serialized delete/re-register races,
idempotent missing object, transient failure/retry, expired lease, exhaustion, account deletion,
cross-user and service-role restrictions) now have passing evidence from the CI database job; only the
Git/PR steps remain.
