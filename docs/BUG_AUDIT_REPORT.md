# Independent QA Audit Report

**Date:** 2026-11-26  
**Repository:** `imo-foad/graduate_Project`  
**QA branch:** `qa/independent-bug-hunt-20261126`  
**QA PR:** https://github.com/imo-foad/graduate_Project/pull/43  
**Builder PR:** #41 — `fix/complete-foundation-and-training-rules-20261126`  
**Builder base SHA:** `6a135b1b8704f09f4a59c1d1f08baf5972939c63`  
**QA head SHA:** `ff2bab6c7986327086d4f48a0787dc77350e9fa8`  
**Latest QA Actions run:** https://github.com/imo-foad/graduate_Project/actions/runs/45861269500  
**Latest run conclusion:** failure in all three jobs; job logs/artifacts were not available from this run. Detailed reproducible failure evidence is from run 45859652000.

## 1. Current conclusion

**Not complete. Do not merge PR #43.** QA fixes are committed and pushed, and PR #43 is synchronized to Builder PR #41 (43 commits ahead, 0 behind). The latest end-to-end Actions run is red. A valid clean database reset fails at Builder migration 0034 before pgTAP, concurrency or local HTTP stages. The static job also fails on a Builder-owned unterminated TypeScript regex and the malformed migration's SQL static check.

The separate university-seed job is marked successful by GitHub, but its own log shows the same migration failure, has no terminal seed PASS/count output, and uploads no artifact. This is a false-success signal caused by the Builder smoke script's EXIT cleanup masking the failed command status. It is **not** accepted as provisioning or idempotency evidence.

QA did not edit Builder-owned migrations, functions, seed fixtures, seed scripts, OpenAPI product docs or workflow lint. Builder handoffs are recorded in PR #41 comments #7197714427, #7197837836 and #7197910866.

## 2. Branch synchronization, PR and ownership

- PR #43: open, not merged; base is `fix/complete-foundation-and-training-rules-20261126`, never `main`.
- Latest compare: 43 ahead / 0 behind, merge base Builder SHA `6a135b1...`.
- Latest sync commit: `658f5b1d0260766a67f679103a82dae2d805edbf`. It uses a normal two-parent merge commit; no force push.
- The merge tree starts from Builder's exact latest tree and overlays only QA-owned files. Verified identical blob SHAs between QA and Builder for Builder-owned `tests/seed.test.ts` and `supabase/migrations/0034_synthetic_university_dataset.sql`; no stale Builder files were overlaid.
- No changes to main, hosted/Cloud Supabase, production records, secrets, or deployment.

### QA-owned files changed in PR #43

- `supabase/tests/database/01_register_for_event.test.sql`
- `supabase/tests/database/02_rpc_rules.test.sql`
- `supabase/tests/database/15_three_type_scope.test.sql`
- `supabase/tests/database/16_cv_cleanup_queue.test.sql`
- `scripts/run-db-tests.sh`
- `scripts/run-local-integrations.sh`
- `tests/db-script-flow.test.ts`
- `tests/integration/university-dataset.integration.mjs` (new)
- `tests/contract_openapi.py` (preserved strict Auth/table-contract checks)
- `docs/BUG_AUDIT_REPORT.md`
- `docs/agent-handoffs/BUGS_FOR_BUILDER.md`

## 3. Continuous regression history — PR #40, #41 and #43

| Regression | QA code / evidence | Current execution result |
|---|---|---|
| PR #40 Test 15 `UNAUTHENTICATED` | User helper stores generated UUID in `tests.ids` before JWT setup; authenticated subject is read from registry; claims and role are established in `tests.as_user` SQL used inside `throws_ok` subtransaction; direct RPC sets claims and role in the test transaction | **Reviewed, not re-executed on current QA head.** Latest clean DB run stopped at migration 0034 before focused Test 15, so complete TAP plan is not yet proven on current head |
| PR #40 Test 16 `FAILED=0` | QA test checks FAILED status and last_error, then `get_cv_cleanup_report()->>'failed' = 1`, then retry eligibility, claim and PROCESSING state; retains abandoned PROCESSING lease recovery | **Reviewed, not re-executed on current QA head.** Older Builder-head runs 45846570698 / 45855098768 reported the preceding Test 16 version OK; QA's added assertions are still not run |
| PR #41 Test 01 FIFO | Confirms cancellation, oldest eligible WAITLISTED user promotion in same transaction, count integrity, later registrant does not leapfrog, WAITLISTED cancellation does not release seat; checks CANDIDATE cancellation and SYSTEM promotion history records | **QA correction not reached** because migration 0034 fails before pgTAP |
| PR #41 Test 02 error contract | TRAINING rejection asserts `NOT_APPLICATION_OPPORTUNITY`; no obsolete `NOT_A_JOB` expectation | **QA correction not reached** because migration 0034 fails before pgTAP |
| PR #41 Test 15 sample isolation | `tests.mk_opp` explicitly writes `is_sample=false`; 7 sample TRAINING rows + 4 isolated test TRAINING fixtures = 11 total; asserts 7 seed rows remain sample-marked and ACTIVE | **QA correction not reached** because migration 0034 fails before pgTAP |
| PR #41 workflow lint | Builder now dynamically discovers four-digit migrations, validates unique/increasing versions and complete migration-ledger coverage. QA runner independently removes fixed migration count and terminal version assumptions | Prior static run 45856864343 passed workflow lint 14/14. **Current run skipped it** because `npm test` failed first |

### Test 15 root cause and exact QA fix

The test helper inserted new rows without `is_sample`; the table default therefore marked test-generated opportunity fixtures as seeded sample data. This mixed four test-owned TRAINING fixtures into the actual seed-catalogue assertion.

QA now sets `is_sample=false` in `tests.mk_opp`. The expected total remains 11 (7 seeded + 4 test fixtures); the test separately asserts exactly 7 seeded TRAINING rows and that all 7 remain ACTIVE. It does not lower the expectation to 10, invent a seed, or change product rules.

The QA runner adds a focused Test 15 invocation with the repository-root-relative path `supabase/tests/database/15_three_type_scope.test.sql`, and requires an actual non-empty TAP plan (`Files=1, Tests>0`) plus `Result: PASS` before the full 18-file suite. The full suite must report `Files=18, Tests>0` and `Result: PASS` before concurrency/HTTP steps. This focused invocation has **not yet reached execution** because migration 0034 fails first.

## 4. Latest detailed QA CI evidence — run 45859652000

Run: https://github.com/imo-foad/graduate_Project/actions/runs/45859652000  
Head: `658f5b1d0260766a67f679103a82dae2d805edbf`.

### Static job — FAIL

`npm test` executed 141 tests: **139 pass, 2 fail**.

1. Builder-owned `tests/seed.test.ts:59` has an unterminated regular-expression literal in the E.164 SQL-shape assertion. Node 22 reports `SyntaxError [ERR_INVALID_TYPESCRIPT_SYNTAX]: Unterminated regexp literal`; the test file cannot load.
2. `tests/sql-static.test.ts` checks migration 0034 and reports `unterminated string` and `unbalanced parentheses (2)`.

Since npm is the first static step, the current run skipped the OpenAPI contract, shell/Node syntax, and workflow-lint steps. Do not carry forward older green results as current-head evidence.

### Database job — FAIL before pgTAP

The job used a clean disposable local Supabase stack. It attempted migrations 0001 through 0034, then failed applying 0034 with:

```
ERROR: syntax error at or near "INSTITUTION_PROVIDER" (SQLSTATE 42601)
and substring(phone from 2) ~ '^[1-9][0-9]{7,14}
alter table public.human_identities
...
```

No migration ledger verification, seed phase, focused Test 15, all-18 pgTAP suite, concurrency, or local HTTP integration was reached. The job failed before any TAP output.

### Synthetic university smoke job — false success, not accepted

GitHub marked the isolated university smoke job as success, but its own log contains the same `supabase db reset` SQLSTATE 42601 at migration 0034. The log has **no** `PASS: synthetic university seed applied twice`, no Auth first/second-pass counts and no dataset count assertion output. The artifact upload step says no files were found. The script's EXIT `cleanup()` ends in `timeout ... || true`, which masks an earlier failure status. Builder has been asked to preserve the original status and always produce a diagnostic log. Until a clean run contains the terminal PASS/count output and a downloadable artifact, dataset provisioning/idempotency remains NOT RUN.

### Downloadable evidence artifact

Artifact: [database-test-logs ZIP](https://github.com/imo-foad/graduate_Project/actions/runs/45859652000/artifacts/15136868752)  
Direct API ZIP: https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15136868752/zip  
Artifact ID `15136868752`; 5,734 bytes; downloaded and inspected. Contains only:
- `environment.txt`
- `supabase-start.log`
- `supabase-status.txt`
- `db-container.log`
- `docker-ps.txt`

No `pgtap.log`, focused Test 15 log, concurrency log, or local HTTP log exists because those stages did not run.

## 5. Synthetic university dataset — fixture inspection vs actual provision

### Fixture-only values verified by inspection

| Measure | Committed fixture |
|---|---:|
| STUDENT | 20 |
| FACULTY | 10 |
| PLATFORM_ADMIN | 10 |
| Existing graduate demos | 4 |
| Distinct GPA values | 20 / 20 |
| GPA range | 2.14–3.94 |
| GPA scale | 4.0 |
| Academic tracks | 7 |
| Unique phone numbers | 40 / 40 |
| Unique Student/Faculty institutional refs | 30 / 30 |
| Email, National ID or password fixture fields | 0 |
| Synthetic Admin human-identity entries | 0 |

Track distribution: Software Engineering 4; Artificial Intelligence 3; Data Science and Analytics 3; Cybersecurity 3; Mobile Development 3; Networks and Cloud 2; Information Systems 2.

The Builder validator requires at least five approved tracks; its current negative fixture is intended to reduce a cloned fixture to four tracks. The fixture data and validator source are not a substitute for actual provisioning evidence.

### Actual database/provisioning/security checks

**NOT RUN / NOT PROVEN.** Because migration 0034 fails before the university seed's database writes, the current run does not prove 20/10/10 Auth accounts, 4 preserved graduate records after seed, Auth/profile/identity/admin counts, second-pass idempotency, GPA constraints, track constraints, faculty data, student/faculty RLS, admin guard, prevention of self-grant, or local-only negative cases.

QA added `tests/integration/university-dataset.integration.mjs` and wired it into `scripts/run-local-integrations.sh` after successful seed. It covers Auth phone accounts/metadata, 20 STUDENT + 10 FACULTY identities, no ADMIN identity, no graduate leakage, 4 preserved graduate demos, Student/Faculty own-record RLS, non-admin denial, legitimate local admin, and client self-grant/write denial. It has **not executed**.

## 6. Broader feature test matrix

| Product area | Latest evidence | Status |
|---|---|---|
| CV cleanup queue SQL | Earlier Builder Test 16 passed; QA test asserts report before claim and retains expired lease recovery | QA version NOT RUN |
| CV Storage worker HTTP deletion/replacement/account deletion | No current HTTP log; DB blocked before integration stage | NOT RUN |
| Recommendation availability | Earlier Builder Test 17 passed in run 45855098768 | Current full path NOT RUN |
| Identity/company SQL tests | Earlier Builder Tests 18/19 passed in run 45855098768 | Current full path NOT RUN |
| Student/Faculty/Admin authorization | QA HTTP integration committed, but migration prevented provision | NOT RUN |
| Social Feed / moderation | Earlier pgTAP tests 12/13 passed in run 45855098768 | Current concurrency and HTTP regressions NOT RUN |
| Onboarding / registration HTTP | Existing local integration harness | NOT RUN |
| CV parser | Builder local PDF/DOCX evaluation harness exists; local integration script also runs it | NOT RUN; no accuracy percentage claimed |
| Rate limits | Existing local HTTP harness | NOT RUN |
| Career cohort round 1 and 2 | Existing local HTTP harness | NOT RUN |
| Real institutional provider / real SMS OTP | External credentials/provider not available | `BLOCKED_EXTERNAL` |

## 7. Builder handoffs

1. **P1 migration 0034 malformed:** E.164 phone CHECK at line 14 has an unclosed SQL string/parentheses before the next ALTER. The verification-source constraint, Student/Faculty tables and RLS blocks are duplicated later in the file. The current DB job reproduces SQLSTATE 42601 near `INSTITUTION_PROVIDER`.
2. **P1 Test seed regex syntax:** `tests/seed.test.ts:59` contains an unterminated regular expression; npm fails at module load.
3. **P1 smoke job false-success:** EXIT cleanup can return success after `supabase db reset` fails. The run showed a migration error but GitHub marked the job successful; no PASS output/artifact. Preserve the original exit code and upload a diagnostic log.
4. **P2 E.164 boundary cases:** Builder Test 19 proves a valid E.164 example and mismatch behavior in older runs, but lacks explicit missing-plus, malformed, leading-zero, too-short and too-long input tests for both retry lookup RPCs.

PR #41 comments with reproduction details:
- #7197714427 — malformed migration 0034 and exact fix expectation.
- #7197837836 — latest static run evidence for migration 0034 and seed regex.
- #7197910866 — smoke job's false-success/EXIT-trap issue.

## 8. Environment limitations and safety

A local Git worktree could not be created because `git ls-remote https://github.com/imo-foad/graduate_Project.git` failed with `Could not resolve host: github.com`. Therefore no local shell/npm/pgTAP/HTTP result is claimed. All verified execution is from GitHub Actions disposable local Supabase. No hosted Supabase or production system was touched.

Real institutional identity API and SMS delivery remain `BLOCKED_EXTERNAL`; mocked local flows must not be represented as real provider tests.

## 9. Delivery status

PR #43 remains open, unmerged and targets Builder PR #41. QA-owned changes are pushed on `658f5b1...`. **Not ready to merge:** Builder must fix migration 0034, the malformed TypeScript test regex and the smoke exit-status trap; then a fresh synchronized run must pass focused Test 15, all 18 pgTAP files, concurrency, local HTTP, university authorization/idempotency, CV parser, onboarding, rate limits and both cohort rounds. Any stage not reached must remain explicitly NOT RUN.


## 10. Latest head/run after final Test02 addition

QA head is now `ff2bab6c7986327086d4f48a0787dc77350e9fa8`; compare is 46 ahead / 0 behind Builder `6a135b1...`. Test02 now explicitly exercises the shared Internship application path as described above. The follow-up Actions run `45861269500` completed with all three jobs marked failure; GitHub did not provide downloadable artifacts or retrievable logs for that run, so no additional failure detail is claimed. The detailed diagnosis remains run `45859652000` and its downloaded artifact.
