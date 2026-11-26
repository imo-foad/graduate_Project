# Independent Bug Audit Report

**Date:** 2026-11-26  
**Repository:** imo-foad/graduate_Project  
**QA branch:** qa/independent-bug-hunt-20261126  
**Target branch:** fix/complete-foundation-and-training-rules-20261126 (not main)  
**Builder HEAD at latest QA rebase:** ffd02350b6280e5ea0672fa6a3333587d0773513  
**Latest observed Builder CI:** https://github.com/imo-foad/graduate_Project/actions/runs/45831195333  
**Original baseline CI:** https://github.com/imo-foad/graduate_Project/actions/runs/45823187268

## 1. Executive result

QA corrected the original test/contract mismatches in database tests 01, 02 and 15; added a precise next-worker retry assertion to test 16; fixed the exact Supabase Auth allowlist in the OpenAPI contract; and aligned DB-runner documentation with 18 pgTAP files and migrations through 0033.

One finding remains open for Builder/maintainer: the P2 workflow-lint test hard-codes 27 migrations although the repository has 32; the file is outside Agent 2's explicit ownership list. The original P1 E.164 lookup defect was corrected by Builder and verified by successful execution of test 19 in the latest disposable-local-Supabase run.

The latest QA branch is rebased on the latest observed Builder HEAD. A completed green run has not been observed for the QA branch. No bug-free claim is made.

## 2. Original CI run 45823187268

Inspected logs show:
- npm test: 143/143 passed.
- OpenAPI contract: 1 failure of 24 tests, because the valid Supabase Auth path /auth/v1/verify was misclassified as a nonexistent project Edge Function.
- pgTAP: 18 files / 630 assertions, with three failures:
  - test 01: obsolete assumption that a new participant takes the seat before automatic FIFO promotion;
  - test 02: stale NOT_A_JOB expectation rather than NOT_APPLICATION_OPPORTUNITY for TRAINING;
  - test 15: test-created CLOSED TRAINING fixture was counted as seeded catalogue content.
- The run visibly executed 19_product_lifecycle.test.sql and reported it ok at that historical baseline. That does not establish later-added assertions passed.
- Concurrency and local HTTP integration were not reached after the failing pgTAP step.

## 3. QA-owned changes

### OpenAPI Auth validation — tests/contract_openapi.py

Added an exact allowlist for /auth/v1/token and /auth/v1/verify. Unknown Auth paths remain rejected, and project endpoints still must map to real Edge Functions. Current Builder OpenAPI documents the token path only; the verify route is accepted if documented but not required.

### Database test 01 — FIFO cancellation

Replaced the obsolete immediate-seat-takeover assertion with checks that confirmed cancellation promotes the oldest eligible WAITLISTED participant, the confirmed counter remains correct, a later new participant stays WAITLISTED, and cancelling that WAITLISTED participant does not free the confirmed seat.

### Database test 02 — application type scope

Renamed the fixture to t_training and asserted NOT_APPLICATION_OPPORTUNITY for TRAINING through the shared application RPC. JOB and INTERNSHIP continue to share the application lifecycle.

### Database test 15 — seeded catalogue invariant

The seed builder marks actual catalogue rows is_sample=true. The fixture catalogue has seven TRAINING entries, all ACTIVE. The test itself creates additional TRAINING fixtures, including a CLOSED one. The invariant now compares only is_sample IS TRUE rows; it still requires every seeded TRAINING to be ACTIVE and does not arbitrarily lower a count.

### Database test 16 — CV cleanup retry

The latest Builder migration 0030 and Android integration guide say FAILED cleanup becomes eligible on the next worker run, and abandoned 15-minute leases are recovered/reclaimed transactionally. The worker Edge Function now stops processing the current batch after a failure so it cannot immediately reclaim the same failed row within one invocation. The QA test is based on the latest Builder test file and adds an explicit next_attempt_at <= now() assertion after failure, preserving immediate eligibility for a subsequent worker run.

### DB runner comments

Updated scripts/run-db-tests.sh comments to say migrations through 0033 and 18 pgTAP files. The runner explicitly enumerates all 18 tests, including test 19, and checks their presence in pgTAP output before proceeding to concurrency and local HTTP integration.

## 4. Builder handoffs

### P1 — Registration E.164 lookup (resolved)

Builder CI run 45829327113 visibly executed test 19 and got INVALID_INPUT from find_pending_registration_retry for a valid synthetic E.164 number under the original double-backslash regex. Builder commit ec7c62e... rewrote both migrations 0030 and 0031 with ^[+][1-9][0-9]{7,14}$. The malformed intermediate commit 4c923 was superseded. The subsequent completed run 45831195333 executed the official local DB runner; its uploaded pgtap.log shows 19_product_lifecycle.test.sql ok and a full summary of 18 files / 651 assertions. This verifies the positive valid-phone lookup path against the corrected migrations. See docs/agent-handoffs/BUGS_FOR_BUILDER.md for historical reproduction and closure evidence.

### P2 — Workflow-lint migration count

Builder CI run 45831195333 on commit ffd023 reported tests/workflow_lint.py:95 failing because the test expected 27 migration files but found 32. The expected fixed list ends at migration 0028. This is stale harness logic, not a defective migration. The file is outside Agent 2's explicit ownership list; QA did not edit it. A dynamic sequence/runner check is recommended in the handoff.

## 5. Wider audit coverage

Inspected representative implementation and regression coverage for:
- CV Storage cleanup queue, owner-scoped metadata deletion, durable private queue, service-role worker functions, retry and lease recovery;
- identity and organization controls, keyed National-ID digests, RLS/service-role identity writes, OTP + identity activation, company memberships and ownership transfer;
- JOB/INTERNSHIP application lifecycle, candidate withdrawal, Training direct registration and FIFO promotion;
- migrations 0030–0033, including retry, verified-company recommendation visibility and cache projection;
- register/finalize-registration/identity-provider/CV-cleanup/recommend Edge Functions;
- Social Feed, moderation/rate-limits and recommendation availability.

Inspected code was not exhaustively runtime-tested. No finding outside the two handoffs is not proof that no other issue exists.

## 6. Verification status

### Original baseline CI 45823187268

| Stage | Result |
|---|---|
| npm test | PASS — 143/143 |
| OpenAPI contract | FAIL — 1/24 |
| pgTAP | FAIL — tests 01, 02, 15; 18 files / 630 assertions |
| Concurrency | Not reached |
| Local HTTP integrations | Not reached |

### Builder CI 45829327113 (before registration regex rewrite)

- npm, OpenAPI and shell/Node stages passed.
- Workflow lint failed: 32 actual migrations vs 27 expected.
- pgTAP failed in 01, 02, 15, 16 and 19; test 19's valid-phone assertion raised INVALID_INPUT. Concurrency and local HTTP were not reached.

### Builder CI 45830097017 (intermediate migration rewrite)

- npm failed the static SQL-structure check on malformed intermediate migration content.
- That intermediate code was superseded by commit ec7c.

### Builder CI 45830300439 (after E.164 rewrite, before worker batch guard)

- npm test: PASS — 143 TAP tests; SQL structure check passed.
- OpenAPI contract: PASS.
- Shell syntax and Node checks: PASS.
- Workflow lint: FAIL — 32 actual vs 27 expected migrations.
- Disposable local database job: CANCELLED after a later push. No pgTAP/test-19/concurrency/HTTP outcome is claimed.

### Latest Builder CI 45831195333 (HEAD ffd023)

- npm test: PASS — 143 TAP tests; visible SQL structure test passed.
- OpenAPI contract: PASS.
- Shell syntax and Node checks: PASS.
- Workflow lint: FAIL — AssertionError: 32 != 27 in test_run_script_covers_all_phases_and_migrations.
- Disposable local Supabase job: FAIL at the pgTAP stage. The uploaded database-test-logs artifact's pgtap.log shows 18 files / 651 assertions. Tests 01, 02 and 15 failed with the exact stale expectations corrected in this QA PR; test 16 passed; test 19 visibly ran and passed. Since pgTAP fails, concurrency and local HTTP integrations were not reached.

The QA branch was updated using GitHub repository APIs. A local checkout/worktree could not be established because outbound GitHub DNS resolution failed, so no local npm/Python/shell/pgTAP/concurrency/HTTP run is claimed. The final QA PR head still needs its own completed CI run before post-change tests can be marked passed.

Real institutional identity-provider and SMS credentials remain BLOCKED_EXTERNAL. No production/cloud Supabase, cloud secrets, deployments or production user data were accessed.

## 7. Delivery

- QA branch: qa/independent-bug-hunt-20261126
- Latest QA commit: d099f981b95ce991350eef94dcf02bd63cd780e2
- PR: https://github.com/imo-foad/graduate_Project/pull/43 (OPEN; base is fix/complete-foundation-and-training-rules-20261126)
- PR #42 was closed during an intermediate rebase; PR #43 is the active replacement.
- QA did not merge.
- QA-owned files: tests/contract_openapi.py, database tests 01/02/15/16, scripts/run-db-tests.sh, and the two audit/handoff docs.
- Workflow run 45832073673 was queued/pending for the final PR head when this report was updated; no QA-PR-specific CI result is claimed.

No bug-free claim is made.
