# Builder Handoffs — Independent QA

This file records defects owned by Builder/product implementation or tests. QA does not modify Builder migrations, product Edge Functions, seed/provisioner implementation, Builder fixtures, product docs or `tests/workflow_lint.py`.

## 1. P1 — migration 0034 is malformed

**File:** `supabase/migrations/0034_synthetic_university_dataset.sql`  
**Current Builder SHA:** `6a135b1b8704f09f4a59c1d1f08baf5972939c63`  
**Reproduction:** clean local `supabase db reset` in GitHub Actions run 45859652000, database job.

The migration ends the phone constraint in the middle of a string:

```sql
and substring(phone from 2) ~ '^[1-9][0-9]{7,14}
alter table public.human_identities
```

PostgreSQL reports `SQLSTATE 42601` near `INSTITUTION_PROVIDER`. npm's `tests/sql-static.test.ts` independently reports `unterminated string` and `unbalanced parentheses (2)`.

The migration also duplicates:
- `human_identities_verification_source_check` (first around line 16, again around line 115);
- `student_academic_records` (around lines 21 and 120);
- `faculty_academic_records` (around lines 41 and 140);
- Student/Faculty RLS policies (around lines 92/94 and 191/193).

Expected: complete and close the E.164 CHECK before the next ALTER; preserve exactly one copy of the verification-source constraint, two academic tables, their validation triggers, grants and RLS policies. Keep it forward-only; do not rewrite historical migrations.

Observed runtime output:
`ERROR: syntax error at or near "INSTITUTION_PROVIDER" (SQLSTATE 42601)`, run 45859652000. The DB reset stopped before seed/pgTAP.

## 2. P1 — Builder's seed test contains an unterminated TypeScript regex

**File:** `tests/seed.test.ts:59`  
**Reproduction:** `npm test` in run 45859652000, static job.

The `assert.match(sql, /.../` expression has no closing regex delimiter or expression terminator. Node 22 emits:
`SyntaxError [ERR_INVALID_TYPESCRIPT_SYNTAX]: Unterminated regexp literal`.

Expected: close the regex correctly or use explicit SQL-fragment assertions. The negative four-track fixture in this same file was corrected in Builder commit 6a135b1; do not regress that fixture. Current npm run reports 141 tests, 139 pass, 2 fail (this module-load error plus migration-shape failure).

## 3. P1 — university seed smoke job masks migration failures

**File:** `scripts/run-university-seed-smoke.sh`  
**Reproduction:** university-seed job in run 45859652000.

The script uses `set -euo pipefail`, but its EXIT trap's `cleanup()` finishes with:
`timeout 120s supabase stop --no-backup ... || true`.

The log shows `supabase db reset` failing on migration 0034 with SQLSTATE 42601. GitHub nevertheless marked the step/job successful. The same log has no `PASS: synthetic university seed applied twice`, no Auth first/second pass counts, no dataset counts, and the artifact uploader reports no files found. No actual seed or idempotency proof exists.

Expected: capture `status=$?` at cleanup entry, disable/avoid recursive EXIT handling, perform best-effort cleanup without replacing the original exit status, and exit with the captured failure. Write a top-level log to the promised artifact path before startup so startup/migration failures always produce downloadable diagnostics. Add a negative CI test that forces `supabase db reset` to fail and asserts the smoke script exits non-zero. Do not mark the synthetic cohort complete until the terminal PASS/count output and artifact are present.

## 4. P2 — E.164 retry lookup boundary test coverage remains incomplete

Builder's corrected validator uses the intended international form, and Test 19 passed on earlier Builder CI heads. Current Test 19 covers a valid example and mismatch behavior but does not explicitly cover:
- missing `+`;
- leading zero after `+`;
- letters/whitespace/malformed string;
- too-short and too-long input;
- 8-digit and 15-digit boundary values;
- both pending-registration and unlinked-pending-registration retry lookup RPCs.

Expected malformed values raise `PT422 INVALID_INPUT`; valid international strings pass input validation and only match exact eligible phone + keyed National-ID digest pairs. Test 19 is Builder-owned; QA has not edited it.

## 5. Previously reported handoffs now resolved

### Workflow migration count

The previous 27-vs-32 hard-coded migration count is resolved in Builder-owned `tests/workflow_lint.py`: it discovers four-digit migration files, validates uniqueness/increasing order and full runner/database-ledger coverage. A previous static run on the intermediate Builder/QA head passed 14/14 workflow-lint tests. Latest run 45859652000 did not reach it because npm failed first.

### Synthetic fixture minimum tracks

Builder validator now requires at least five approved tracks; Builder also corrected its negative four-track test fixture in commit 6a135b1. Current source is structurally correct there, but `tests/seed.test.ts` cannot load because its adjacent E.164 regex assertion is unterminated.

### OpenAPI academic record paths

Builder added GET documentation for `student_academic_records` and `faculty_academic_records` in `docs/openapi.yaml`. A prior static run on intermediate head fda0e0d passed the OpenAPI contract. Latest run 45859652000 did not reach OpenAPI because npm failed first.

## 6. QA regression fixes awaiting clean execution

QA PR #43 includes:
- Test01 FIFO cancellation/promotion, count integrity, WAITLISTED cancellation and candidate/system status-history checks.
- Test02 `NOT_APPLICATION_OPPORTUNITY` contract for TRAINING.
- Test15 helper sets `is_sample=false` for every test fixture, preserving 7 sample TRAINING rows + 4 test fixtures = 11 and asserting 7 seeded rows remain ACTIVE.
- Test16 checks FAILED and report before retry claim, separate eligibility/claim/PROCESSING assertions, and expired PROCESSING lease recovery.
- A focused Test15 pgTAP preflight using `supabase test db supabase/tests/database/15_three_type_scope.test.sql`, with non-empty TAP-plan and PASS guards before full 18-file pgTAP.
- Full-suite guards require `Files=18, Tests>0`, every expected file, and `Result: PASS` before concurrency/HTTP.

Run 45859652000 stopped at migration 0034, so none of these current QA pgTAP changes have run. Do not report Test15's authentication/TAP plan or Test16's reconciliation assertions as proven on this head yet.

## 7. Synthetic university dataset — what is known and what is not

Fixture inspection shows:
- 20 STUDENT, 10 FACULTY and 10 PLATFORM_ADMIN entries;
- 20 distinct GPA values, range 2.14–3.94, scale 4.0;
- seven approved tracks with counts 4/3/3/3/3/2/2;
- 40 unique synthetic phones and 30 unique student/faculty institutional references;
- no email, National ID or password fields;
- admins have no human `identity_type`;
- four original graduate demo entries remain in the existing fixture.

These are fixture facts only. Actual Auth provisioning, DB counts, second-run idempotency, RLS/privacy, admin grants, preservation of graduate profiles and local-only negative tests remain NOT RUN because migration 0034 fails first.

QA added `tests/integration/university-dataset.integration.mjs` to verify the live local API after seeding. It has not executed.

## 8. Latest run and artifact evidence

Run 45859652000: https://github.com/imo-foad/graduate_Project/actions/runs/45859652000

- Static/npm: 141 tests, 139 pass / 2 fail (seed TypeScript regex + malformed 0034 static shape). OpenAPI, shell/Node validation and workflow lint skipped.
- Database: clean disposable reset failed at 0034 with SQLSTATE 42601. Focused Test15, all pgTAP, concurrency and local HTTP were not reached.
- University smoke: GitHub shows success, but log contains the same 0034 SQLSTATE failure, has no terminal PASS or dataset counts, and no artifact was produced. Treat as false success; seed/idempotency are NOT RUN.
- Database artifact ID `15136868752`: https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15136868752/zip. Downloaded and inspected; contains environment, supabase-start, status, db-container and docker logs only, no pgTAP/concurrency/HTTP logs.

Real institutional identity provider and real SMS/OTP remain `BLOCKED_EXTERNAL`; deterministic local mocks are not real provider evidence.
