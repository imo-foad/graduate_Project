# Issues #18 / #24 — baseline before implementation

**Recorded:** 2026-11-27
**Base:** `main` at `c44aaf4217f45d41b58b83cdd6618b71f5e34b7f` (fetched from `origin/main` during this session; latest main CI run
[45948145595](https://github.com/imo-foad/graduate_Project/actions/runs/45948145595) succeeded on that SHA).
Both issue branches are created from this commit. No commit on `main` was created, amended or pushed.

## Environment used for this baseline

| Capability | State |
|---|---|
| Node.js | 22.x (unit / static suite runnable) |
| Python 3.12 + PyYAML | runnable in a local virtualenv |
| Deno 2.9.8 | downloaded into `/tmp` for parser-only execution (not a project dependency) |
| Docker daemon | **not available** in this cloud runner |
| Supabase CLI, `psql`, `pg_prove` | **not available** |
| Disposable local Supabase stack (Auth/Storage/Kong) | **not available here**; runs in GitHub Actions |

Consequence: this session can execute the Node suite, the OpenAPI contract, the workflow lint, and
the parser modules through Deno. The pgTAP, concurrency, real-Storage HTTP and Edge Function suites are
**BLOCKED_ENVIRONMENT locally** and are executed by the existing `backend-tests` workflow (Docker +
Supabase CLI 3.3.0). No test below is reported as passing unless it ran.

## Recorded baseline results

| Command | Result | Count |
|---|---|---|
| `npm test` | PASSED | 187 / 187 |
| `python3 -m unittest tests/contract_openapi.py` | PASSED | 24 / 24 |
| `python3 -m unittest tests/workflow_lint.py` | PASSED | 14 / 14 |
| `npm run test:db` | BLOCKED_ENVIRONMENT | no Docker / Supabase CLI / `psql` |
| `npm run evaluate:cv:local` | BLOCKED_ENVIRONMENT | requires the local Supabase HTTP stack |

`scripts/run-db-tests.sh` was read before being invoked. It refuses non-local `DB_URL` values, requires the
Supabase DB port (`54322`), starts the local stack, resets it, and fails on any error. It was **not** run
because its required tools are absent; no Cloud or remote database was contacted at any point.

## Confirmed defects and gaps on this baseline

### Issue #18 — durable CV Storage cleanup

1. **A queued cleanup can delete a live object.** `private.cv_cleanup_queue` rows are not re-checked
   against `public.cv_documents.storage_path`. If metadata is deleted (cleanup queued) and the same object
   key is registered again before the worker runs, the worker deletes the live object. Migration 0027
   triggers neither cancel nor guard this.
2. **Retries are immediate and unbounded in spacing.** `fail_cv_cleanup` sets `next_attempt_at = now()`, so
   a persistent Storage failure consumes all ten attempts on consecutive worker invocations. The
   reconciliation report therefore cannot distinguish "retry scheduled" from "retry ready".
3. `get_cv_cleanup_report()` counts `pending` as *all* PENDING rows, including operator-requeued rows, and
   does not describe never-attempted work separately.
4. No test uploads a real object and proves its bytes are gone after the worker; `16_cv_cleanup_queue.test.sql`
   proves database transitions only. `rate-limits.integration.mjs` drives the worker, but only over paths that
   have no object, so it proves idempotence rather than deletion.
5. No failure/retry test at the worker's Storage transport boundary; no expired-lease E2E test; no exhausted
   attempt E2E test; no account-deletion E2E test that checks object absence.
6. `cleanup-cv-objects` built its Supabase client inline with no injectable seam and no request timeout, so the
   failure path could only be tested by editing production code or adding a fault-injection parameter.

### Issue #24 — CV extraction quality

7. **Arabic DOCX misses attached Latin skills.** `extractSkillsFromText` requires the character before a term
   to be a non-letter. Arabic attaches the conjunction `و` directly (`وSQL`, `وKotlin`), so the lookbehind sees
   an Arabic letter and rejects the match. This is the root cause of the observed SQL/Kotlin misses.
8. **DOCX tables lose cell boundaries.** Only `</w:p>` and `w:tab` are handled, so cells of one table row
   become separate lines and employer/title columns are separated into unrelated lines.
9. **Multi-column PDF text is flattened.** `extractCvText` concatenates `getTextContent()` items in stream
   order with `hasEOL` newlines only. PDF.js items are positioned by transform, not reading order, and a
   horizontal gap that separates employer from job title is collapsed into a space.
10. The benchmark has four fixtures (three PDF, one DOCX), aggregate-only thresholds (skills recall ≥ 0.75),
    no negative fixtures, no per-field gates, and the "layout limitation" fixture asserts the broken merge as
    expected output. There is no consented real-CV corpus.

## Overlapping pull-request risk

| PR | Branch | Relevance |
|---|---|---|
| #40 | `feat/backend-phases-1-3` → `main` | Contains historical copies of `0027_cv_storage_lifecycle.sql`, `16_cv_cleanup_queue.test.sql` and `cleanup-cv-objects/index.ts` that are already on `main`. This work is additive on top of `main`; if #40 is merged later it will need a rebase. No code was taken from it. |
| #7 | `fix/cv-parse-lifecycle-test-contract-20261124` → `main` | Touches only `08_cv_parse_lifecycle.test.sql`; not modified here. |
| #43 | `qa/independent-bug-hunt-20261126` → unmerged foundation branch | Stacked on an unmerged branch; not used as a base and not modified. |
| #33 / #45 / #46 / #2 | various → `main` / `backend-initial-import` | No overlap with CV storage cleanup or parser modules. |

Neither issue branch is based on another PR: both start at `main` `c44aaf4`.

## Planned acceptance tests

Issue #18: real-object owner deletion; replacement (old removed, new intact); re-used object key; already-missing
object; rejected unsafe path; recorded Storage failure with scheduled retry; expired lease recovery; concurrent
claims; exhausted attempts with operator requeue; full approved account deletion; direct/client/worker
authorization; worker log hygiene.

Issue #24: Arabic DOCX attached-skill regression; DOCX table extraction; layout-aware PDF line/column grouping;
per-field precision/recall gates (skills/experience/certifications/courses) over a ≥10-scenario synthetic corpus
with negative fixtures; malformed/empty/oversized/foreign/concurrent parse HTTP tests; pending-review and
profile-update guarantees. Synthetic results will not be presented as real-CV accuracy, and #24 stays open.
