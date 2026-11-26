# Independent QA Audit Report

**Date:** 2026-11-26  
**Repository:** `imo-foad/graduate_Project`  
**QA branch:** `qa/independent-bug-hunt-20261126`  
**PR:** https://github.com/imo-foad/graduate_Project/pull/43  
**Builder PR:** #41 — `fix/complete-foundation-and-training-rules-20261126`  
**Latest Builder head inspected:** `329a0be14d49f5c1c1f2efe5273495dda09f3b25`  
**Latest Builder Actions run inspected:** https://github.com/imo-foad/graduate_Project/actions/runs/45846570698

## 1. Current conclusion

This is a partial QA delivery, not a full acceptance. The latest Builder run passed static/unit, OpenAPI, shell/Node syntax, and dynamically discovered workflow-lint checks. Its clean disposable-local-Supabase job applied all 32 migrations and ran all 18 pgTAP files (658 assertions), but failed one assertion in test 15. The exact root cause is now corrected on the QA branch. The corrected Test 15, additional Test 01 history assertions, and focused Test 15 runner have not yet been executed by a new post-change CI run.

The requested 20 STUDENT + 10 FACULTY + 10 local administrator synthetic university dataset is not present in the inspected Builder head. QA did not invent a fixture, GPA scale, track vocabulary, or schema. This is an explicit Builder handoff.

## 2. Latest baseline evidence — Builder run 45846570698

Run URL: https://github.com/imo-foad/graduate_Project/actions/runs/45846570698  
Run number: 765; Builder head: `329a0be14d49f5c1c1f2efe5273495dda09f3b25`.

### Static job — PASS

- `npm test`: 143/143 Node TAP tests passed; the SQL migration-structure check passed.
- OpenAPI contract: 24/24 tests passed.
- Shell syntax and Node syntax checks passed.
- Workflow lint: 14/14 tests passed after Builder's dynamic migration-discovery fix.

### Clean disposable local Supabase job — FAIL at pgTAP

- Local Supabase started and the database was reset from empty.
- Reset log shows 32 migrations applied, from 0001 through 0033 (there is no 0022 migration).
- Seed build and the two-pass skill/catalogue seed completed; the runner reported 50 skills and 21 opportunities, idempotent on the second load.
- pgTAP executed all 18 files: 658 assertions total.
- The sole failing file was `15_three_type_scope.test.sql`, assertion 16: actual active TRAINING rows = 10, expected total TRAINING rows = 11.
- Test files 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 12, 13, 14, 16, 17, 18 and 19 reported `ok` in that Builder-head run.
- Since the runner is fail-fast, concurrency and local HTTP integration were not reached. Onboarding, CV parser HTTP integration, rate-limit HTTP integration and both career-cohort rounds are therefore NOT RUN in that run.

The Builder run did not contain the QA branch's later changes to tests 01/02/15/16, so its passing results are baseline evidence for the Builder-head files only, not post-change proof of the QA PR.

### Downloadable diagnostics

GitHub artifact: [database-test-logs ZIP](https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15131653447/zip)  
Artifact ID: `15131653447`; name: `database-test-logs`; size: 107,341 bytes; expiry shown by GitHub: 2026-12-03.

The artifact was downloaded and inspected. It contains:
- `db-container.log`
- `db-reset.log`
- `docker-ps.txt`
- `environment.txt`
- `pgtap.log`
- `supabase-start.log`
- `supabase-status.txt`

No concurrency or local-HTTP log exists in this artifact because those stages were not reached.

## 3. Continuous regression history — PRs #40, #41 and #43

### PR #40 — Test 15 authentication / Test 16 reconciliation

**Test 15 authentication protection:** the helper creates a user, inserts the UUID into `tests.ids`, then returns. The authenticated RPC uses that registered UUID as `request.jwt.claims.sub`; role is set to `authenticated`. The `tests.as_user` helper includes both JWT claims and role setup in the SQL passed to `throws_ok`, keeping identity setup with the expected-error RPC invocation in its pgTAP subtransaction. The latest Builder-head pgTAP run got through all 16 assertions in that earlier Test 15 version and failed only its catalogue assertion, not with UNAUTHENTICATED. The QA branch retains the registry/auth setup and adds further catalogue assertions; those latest assertions await the next CI run.

**Test 16 reconciliation protection:** the current QA test checks that the failed row is still `FAILED`, preserves `last_error`, reads `get_cv_cleanup_report()->>'failed'` before another claim, checks retry eligibility, then claims and separately verifies `PROCESSING`. It also retains abandoned PROCESSING lease recovery. The Builder-head test 16 reported `ok` in run 45846570698. QA's additional `next_attempt_at <= now()` assertion awaits the post-change run.

### PR #41 — product continuation regressions

**Test 01:** QA asserts confirmed cancellation, FIFO promotion of the oldest waiting participant, the confirmed counter, no seat stealing by a later participant, and no seat decrement/promotion from cancelling a WAITLISTED row. It now also asserts separate `CANDIDATE` cancellation and `SYSTEM` promotion history records.

**Test 02:** QA asserts `NOT_APPLICATION_OPPORTUNITY` for TRAINING and does not restore the obsolete `NOT_A_JOB` expectation. The shared JOB/INTERNSHIP lifecycle is also exercised in the Builder-owned product lifecycle suite.

**Test 15:** see the root cause and exact correction below. No seed fixture was added and no product rule was changed.

**Workflow lint:** Builder corrected `tests/workflow_lint.py` in the two commits after QA's previous base. It now discovers four-digit migration filenames, checks unique/increasing version prefixes, and verifies that the DB runner dynamically discovers files and compares the complete applied migration ledger. No fixed migration count or terminal migration version remains. The latest Builder workflow lint passed 14/14 tests.

### Test 19 phone validation

The latest Builder-head run reports `19_product_lifecycle.test.sql ... ok`. The test proves a valid synthetic E.164 phone resolves the exact pending phone + keyed National-ID digest pair, rejects a mismatched phone/digest, and denies authenticated enumeration. The corrected SQL validator uses `^[+][1-9][0-9]{7,14}$`. The current test does not exercise malformed, too-short, and too-long phone inputs; that missing boundary coverage is handed back to Builder because test 19 is outside Agent 2's owned SQL range.

## 4. Test 15 root cause and QA correction

The `tests.mk_opp` helper inserted test-owned opportunity rows without specifying `is_sample`. The column default marked these local test fixtures as sample data. Test 15 creates four TRAINING fixtures, including a CLOSED one. The approved catalogue fixture contains seven TRAINING rows. Mixing the four test rows into the sample-catalogue query caused the earlier active-vs-total count mismatch (10 vs 11).

QA changed only `supabase/tests/database/15_three_type_scope.test.sql`:
- `tests.mk_opp` now explicitly inserts `is_sample=false`.
- The test preserves the 11-row total within this test transaction: seven seeded TRAINING catalogue rows plus four test-owned TRAINING fixtures.
- It asserts there are exactly seven seeded `is_sample=true` TRAINING rows.
- It separately asserts every seeded TRAINING row remains ACTIVE.
- The expected count was not lowered to 10; no fake seed opportunity was added.

The runner now executes `supabase test db database/15_three_type_scope.test.sql` as a focused preflight before the full 18-file pgTAP suite, and stores its output in `.ci-logs/pgtap-15-focused.log`. `tests/db-script-flow.test.ts` now covers the focused failure path. This implementation is based on the Supabase CLI's documented `supabase test db [path]` interface; the next CI run must prove it against the repository's pinned CLI.

## 5. Synthetic university dataset — NOT IMPLEMENTED on Builder head 329a0be

Inspection of the actual Builder branch shows:
- `fixtures/demo-profiles.json` contains exactly four existing GRADUATE demo profiles.
- `scripts/provision-demo-users.mjs` provisions those fixture entries; it does not provision 20 students, 10 faculty or 10 synthetic administrators.
- `scripts/build-seed.mjs` generates only skills, opportunity catalogue and the four graduate demo profile seed files.
- `supabase/seed/03_demo_profiles.sql` updates existing graduate profiles and related graduate career data.
- Migration 0028 defines human identity types `STUDENT`, `GRADUATE` and `FACULTY`; `ADMIN` is not a supported human identity type.
- `scripts/bootstrap-platform-admin.mjs` bootstraps one first platform admin via the server-owned bootstrap RPC; it is not a ten-admin local synthetic dataset provisioner.
- The current fixture contract contains no GPA field, GPA scale, or academic-track vocabulary.

The separate career-cohort fixtures are two rounds of ten GRADUATE test users, not the requested student/faculty/administrator university dataset. Consequently no valid evidence exists for 20/10/10 counts, GPA uniqueness/range, track distribution, faculty attributes, student/faculty privacy, admin membership counts, or dataset-specific two-pass idempotency. QA did not fabricate a schema or fixture to force these checks.

The existing `provision-demo-users.mjs` consumes a supplied `SUPABASE_URL` and service-role key without its own explicit local-host allow-list. The local test runner controls its current call path, but direct invocation is not independently guarded. Builder should add an explicit local URL guard plus tests before treating any synthetic account provisioner as local-only.

## 6. Broader feature test matrix and limits

| Area | Evidence in latest Builder run | Not yet proven |
|---|---|---|
| CV cleanup queue | pgTAP test 16 passed; covers FAILED reporting, next-claim flow and expired lease recovery in the Builder version | QA's added retry-time assertion, actual Storage worker HTTP deletion/replacement race and end-to-end lifecycle after pgTAP |
| Recommendation availability | pgTAP test 17 passed | HTTP/local-cache integration not reached |
| Identity and organizations | pgTAP test 18 passed; product lifecycle test 19 passed | onboarding HTTP workflow not reached; real institutional provider and SMS remain BLOCKED_EXTERNAL |
| Social Feed/moderation | pgTAP tests 12 and 13 passed | live concurrent-like tests not reached |
| CV parsing | parser integration and career-cohort harness exist in the runner | HTTP parse integration and both cohort rounds not reached; no independent Arabic/DOCX corpus result claimed |
| Synthetic university records | no 20/10/10 dataset contract found | all dataset-specific functional/security/idempotency checks remain BLOCKED_MISSING_IMPLEMENTATION |

Scanned/image-only PDF OCR is not claimed. Real institutional API and SMS delivery remain `BLOCKED_EXTERNAL`; only disposable-local mocks may be used.

## 7. Execution and environment limitations

The latest evidence above is from GitHub Actions on its fresh disposable local Supabase runner. No hosted Supabase environment was touched.

A local checkout/worktree could not be created in this environment: `git ls-remote https://github.com/imo-foad/graduate_Project.git` failed with `Could not resolve host: github.com`. Thus no local npm/Python/shell/pgTAP/HTTP command is claimed. Repository changes were made on the isolated QA branch through GitHub repository APIs. A new Actions run on the synchronized QA PR head is required to validate those commits.

## 8. Delivery status

- QA PR: https://github.com/imo-foad/graduate_Project/pull/43 (open; never merged).
- No changes to `main`, Cloud Supabase, production data, or hosted secrets.
- Full completion is pending the post-change QA CI, focused Test 15, all pgTAP tests, concurrency, local HTTP integrations, onboarding, parser integration, rate limits and both career-cohort rounds.
