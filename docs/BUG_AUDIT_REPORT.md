# Independent QA Audit Report

**Date:** 2026-11-26  
**Repository:** `imo-foad/graduate_Project`  
**QA branch:** `qa/independent-bug-hunt-20261126`  
**QA PR:** https://github.com/imo-foad/graduate_Project/pull/43  
**Builder PR:** #41 — `fix/complete-foundation-and-training-rules-20261126`  
**Latest Builder head inspected:** `3dd22f7f136a07a19d1933411fa6a49f66a58b51`  
**Latest Builder Actions run inspected:** https://github.com/imo-foad/graduate_Project/actions/runs/45855098768

## 1. Current conclusion

This is a partial QA delivery, not a full acceptance. The latest Builder head introduces the synthetic university dataset (20 STUDENT, 10 FACULTY, 10 local platform-admin accounts) and migration 0034. The JSON fixture satisfies the requested counts, GPA distribution, and seven-track distribution. However, the latest Builder CI failed both the OpenAPI contract and pgTAP, so the new university provisioning and HTTP authorization stages were never reached.

QA has fixed the owned Test 01/02/15/16 regressions, added explicit status-history assertions, added a focused Test 15 runner stage, removed fixed migration-count/terminal-version assumptions from the QA DB runner, and added an independent local HTTP test for synthetic identities, academic-record RLS and the admin guard. Those QA changes still need to be synchronized with the latest Builder head and executed in CI. No success is claimed for tests not yet run on the current QA head.

## 2. Latest Builder baseline — run 45855098768

Run URL: https://github.com/imo-foad/graduate_Project/actions/runs/45855098768  
Builder head: `3dd22f7f136a07a19d1933411fa6a49f66a58b51`.

### Static job

- `npm test`: PASS — 149/149 Node TAP tests.
- OpenAPI contract: FAIL — 24 tests run, 1 failure.
- Exact failure: `tests/contract_openapi.py::Contract.test_every_granted_table_capability_is_documented`, line 130: `student_academic_records: granted but undocumented`.
- Shell syntax / other static steps and workflow lint were skipped after the OpenAPI step failed. Do not call current-head workflow lint green based on this run.

### Clean disposable local Supabase job

- Supabase started on the isolated GitHub runner.
- All 33 migration files were applied, through `0034_synthetic_university_dataset.sql` (there is no 0022 migration).
- Seed builder generated `01_skills.sql`, `02_catalogue.sql`, `03_demo_profiles.sql`, and `04_university_accounts.sql`.
- Skill/catalogue seeds ran twice and were idempotent: 50 skills and 21 opportunities.
- pgTAP executed 18 files, 651 assertions. Three legacy QA assertions failed:
  - Test 01 assertion 23: expected later registrant `REGISTERED`, actual `WAITLISTED`; the test still had the old expectation that cancellation leaves the seat open instead of transactionally promoting the waitlist.
  - Test 02 assertion 8: expected `NOT_A_JOB`, actual `NOT_APPLICATION_OPPORTUNITY`.
  - Test 15 assertion 16: actual 10 active vs expected 11 because test fixtures were inserted with the schema default `is_sample=true`.
- Test 16 and Test 19 reported `ok` in this Builder-head run; tests 03–14, 17, and 18 also reported `ok`.
- Because pgTAP failed, concurrency and all local HTTP stages were NOT REACHED. This includes the new synthetic dataset provisioner, RLS/admin integration, onboarding, CV parser integration, rate-limit integration and career-cohort rounds 1 and 2.

### Downloadable logs

GitHub artifact: [database-test-logs ZIP](https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15136086556/zip)  
Artifact ID: `15136086556`; artifact name `database-test-logs`; downloaded and inspected. It contains:
- `db-container.log`
- `db-reset.log`
- `docker-ps.txt`
- `environment.txt`
- `pgtap.log`
- `supabase-start.log`
- `supabase-status.txt`

It contains no concurrency or local HTTP logs because those stages were not reached.

## 3. Continuous regression history — PR #40, #41 and #43

### PR #40 — Test 15 authentication regression

The test user helper inserts the generated UUID into `tests.ids` before returning it. The JWT subject is taken from that registry. The direct authenticated call sets `request.jwt.claims` and `role` inside the transaction; the `tests.as_user` helper embeds the claims and role setup in the SQL passed to `throws_ok`, so identity initialization is part of the same pgTAP subtransaction that invokes the RPC.

Latest Builder-head Test 15 reached its catalogue assertion and failed there; it did not reproduce the historic `UNAUTHENTICATED` crash. QA retains the helper and setup. A post-fix focused Test 15 run is still required to prove the complete current TAP plan executes.

### PR #40 — Test 16 CV cleanup reconciliation regression

Current QA Test 16 verifies:
1. the failed queue row is still `FAILED`;
2. `last_error` is retained;
3. `get_cv_cleanup_report()->>'failed'` equals 1 before retry claim;
4. retry eligibility (`next_attempt_at <= now()`) is asserted separately;
5. the next claim returns the retry row;
6. its state/report becomes `PROCESSING`;
7. an abandoned `PROCESSING` lease is recovered on a later claim.

Builder-head Test 16 reported `ok` in run 45855098768. QA's added retry-eligibility assertion needs the post-sync QA run.

### PR #41 — Test 01 FIFO and history

QA Test 01 asserts confirmed cancellation, FIFO promotion of the oldest eligible WAITLISTED user, correct registered counter, no later-seat leapfrogging, and no false seat release/promotion when a WAITLISTED entry is cancelled. It now also checks the exact history events:
- REGISTERED → CANCELLED with actor = cancelling user and source = `CANDIDATE`;
- WAITLISTED → REGISTERED with null actor and source = `SYSTEM`.

The latest Builder run still executed the old Test 01 and failed its obsolete assertion. QA's corrected version has not yet executed.

### PR #41 — Test 02 contract

QA Test 02 expects `NOT_APPLICATION_OPPORTUNITY` for TRAINING and does not reintroduce `NOT_A_JOB`. JOB and INTERNSHIP share the approved application workflow. Latest Builder run still used the old test and failed its obsolete error-code assertion.

### PR #41 — Test 15 sample isolation

The root cause is the helper `tests.mk_opp`: it omitted `is_sample`, so the column default marked the six helper-created opportunity fixtures as catalogue samples. Four of those are TRAINING fixtures; they contaminated the seeded catalogue assertion.

QA now explicitly inserts `is_sample=false` for every test-owned opportunity. It retains the 11 TRAINING rows inside this test transaction (7 seeded rows + 4 isolated test fixtures), asserts exactly 7 seeded `is_sample=true` TRAINING rows, and asserts all 7 seeded rows remain ACTIVE. It does not lower the count to 10, add a fake seed row, or alter product rules.

QA also added a focused `supabase test db database/15_three_type_scope.test.sql` preflight to `scripts/run-db-tests.sh`, with its own log and a guard that confirms the Test 15 filename actually appears before the full 18-file suite starts.

### PR #41 — Workflow lint and migration discovery

Builder's `tests/workflow_lint.py` dynamically discovers four-digit migration files, checks unique/increasing versions, and validates that the DB runner requires all discovered versions in the applied migration ledger. The latest run 45855098768 did not execute workflow lint because the OpenAPI step failed first.

QA independently removed the fixed `-ge 22` minimum and the stale “through 0033” comment from its owned `scripts/run-db-tests.sh`. It validates discovered filenames, unique/increasing four-digit versions, reset output for each discovered migration, and exact equality with `schema_migrations`; it contains no fixed migration count or terminal version. The new QA run must execute the full static stage to prove the DB-runner flow tests and workflow lint.

### Test 19 — phone validation

Builder's Test 19 reported `ok` in latest Builder run 45855098768; the corrected E.164 validator uses `^[+][1-9][0-9]{7,14}$`. The existing Test 19 covers valid international format and mismatched phone/digest but does not explicitly cover malformed, too-short and too-long phone cases. Test 19 is Builder-owned; QA has not edited it. Boundary cases remain a Builder handoff.

## 4. Synthetic university dataset — independent inspection

Latest Builder commit `3dd22f7f136a07a19d1933411fa6a49f66a58b51` adds:
- `fixtures/university-accounts.json`;
- migration `0034_synthetic_university_dataset.sql`;
- `scripts/provision-university-demo-users.mjs`;
- `scripts/seed-university-demo.mjs`;
- a fourth generated SQL seed file;
- dataset documentation and operations notes.

### Fixture facts observed

| Check | Observed |
|---|---:|
| STUDENT accounts | 20 |
| FACULTY accounts | 10 |
| PLATFORM_ADMIN accounts | 10 |
| Existing GRADUATE demo profiles retained | 4 |
| Distinct student GPA values | 20 / 20 |
| GPA range | 2.14–3.94 |
| GPA scale | 4.0 for all |
| Academic tracks | 7 distinct |
| Unique synthetic phone numbers | 40 / 40 |
| Unique Student/Faculty institution refs | 30 / 30 |
| Email / National ID / password fields in fixture | 0 |
| Synthetic admin human-identity entries | 0 (fixture contains no `identity_type` for admins) |

Track distribution:
- Software Engineering: 4
- Artificial Intelligence: 3
- Data Science and Analytics: 3
- Cybersecurity: 3
- Mobile Development: 3
- Networks and Cloud: 2
- Information Systems: 2

The provisioner creates phone-only Auth users with confirmed synthetic marker metadata, reuses only matching seed/phone accounts, and enforces the API local allow-list. The legacy graduate demo provisioner now calls the same local URL guard. The database seed checks local API + DB URLs before network/database operations, runs Auth provisioning twice and expects 0 new / 40 reused on pass two, applies SQL twice, and checks exact counts including 20 student records, 10 faculty records, 10 active private platform admins, 0 graduate profiles for the 40 new accounts and four preserved graduates.

Migration 0034 defines GPA range/scale constraints, academic-track vocabulary, faculty title vocabulary, a trigger requiring a matching VERIFIED STUDENT/FACULTY identity, and own-profile SELECT RLS. Service role owns writes. The human identity allowlist remains STUDENT/GRADUATE/FACULTY; ADMIN is not introduced as a human identity.

### Dataset gaps found in code review

1. `validateUniversityFixtures()` only rejects fewer than **2** distinct tracks (`tracks.size < 2`), although acceptance requires at least **5**. The current committed fixture has seven, and the QA-owned independent fixture test now asserts at least five; the Builder validator itself remains too permissive for future fixture changes.
2. OpenAPI contract fails because authenticated SELECT is granted on `student_academic_records` and `faculty_academic_records` but these table paths are not documented. The exact latest failure names `student_academic_records`; the faculty table is subject to the same grant-vs-documentation contract and may be the next assertion once the first is fixed. Builder owns `docs/openapi.yaml`; QA deliberately did not weaken its grant/documentation test.
3. Latest CI stopped before synthetic seed execution, so Auth provisioning idempotency, real DB counts, student/faculty record RLS, admin self-grant denial, and preservation of the four graduate records remain NOT RUN in the latest run. QA added `tests/integration/university-dataset.integration.mjs` and wired it after the local university seed; that new integration has not yet been executed.
4. The actual validator test in Builder's `tests/seed.test.ts` checks fixture values and negative GPA/track/ref cases, but does not assert that validator rejects a fixture with only 2–4 distinct tracks. The handoff asks Builder to enforce the minimum five-track contract.

No real National IDs or user personal records were added. Real institutional verification API and real SMS delivery remain `BLOCKED_EXTERNAL`; all synthetic provisioning is local-only.

## 5. QA-owned changes currently staged on QA branch

- `supabase/tests/database/01_register_for_event.test.sql`
- `supabase/tests/database/02_rpc_rules.test.sql`
- `supabase/tests/database/15_three_type_scope.test.sql`
- `supabase/tests/database/16_cv_cleanup_queue.test.sql`
- `scripts/run-db-tests.sh`
- `scripts/run-local-integrations.sh`
- `tests/db-script-flow.test.ts`
- `tests/integration/university-dataset.integration.mjs` (new)
- `tests/contract_openapi.py` (unchanged regression contract)
- `docs/BUG_AUDIT_REPORT.md`
- `docs/agent-handoffs/BUGS_FOR_BUILDER.md`

## 6. Execution status and limits

- Latest Builder run executed 149/149 npm tests, 24 OpenAPI checks (1 failed), 33 migration applications, idempotent base seeds and 18 pgTAP files / 651 assertions (three failures).
- Concurrency, local HTTP integration, synthetic dataset provisioning, student/faculty/admin authorization checks, CV parser HTTP tests, onboarding, rate limits and cohort round 1/2 were NOT REACHED.
- No post-fix QA CI run is yet available for the branch synchronized with Builder 3dd.
- A local checkout/worktree could not be created in this environment: `git ls-remote https://github.com/imo-foad/graduate_Project.git` failed with `Could not resolve host: github.com`. All file changes were pushed through GitHub repository APIs; no local shell/npm/pgTAP/HTTP result is claimed.
- No Cloud Supabase, production credentials/data, or main branch changes; PR #41/#43 were not merged.

## 7. Delivery state

PR #43 remains open and targets Builder PR #41's branch, not main. Full acceptance remains pending a current synchronized QA Actions run and all stages listed above. Do not treat fixture shape or a commit as proof of database provisioning and authorization.
