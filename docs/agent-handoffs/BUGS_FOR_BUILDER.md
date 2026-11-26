# Builder Handoffs — Independent QA

## 1. P1 registration retry E.164 validation — implementation RESOLVED; boundary test coverage OPEN

**Implementation status:** RESOLVED in Builder migrations 0030/0031. The latest Builder run 45846570698 executed `19_product_lifecycle.test.sql` successfully. The current validator uses `^[+][1-9][0-9]{7,14}$`.

**Historical defect:** Earlier `find_pending_registration_retry(text,text)` / `find_unlinked_pending_registration_retry(text)` SQL regex escaping rejected valid leading-plus numbers. The failure surfaced as `INVALID_INPUT` / registration retry failure. This was corrected by Builder; QA did not modify migrations 0030/0031, Edge Functions or test 19.

**Remaining coverage request:** The current Test 19 has a valid E.164 case and mismatched phone/digest cases, but no explicit malformed, too-short, or too-long phone assertions. Add pgTAP cases for at least:
- valid boundary numbers with 8 and 15 digits after '+';
- too-short number;
- too-long number;
- missing '+', leading zero after '+', letters/whitespace;
- equivalent checks for both pending and unlinked retry lookup RPCs.

Expected: malformed/too-short/too-long values raise `PT422 INVALID_INPUT`; valid international-format values pass input validation and only resolve an exact eligible phone + keyed digest match. Keep test 19 Builder-owned unless ownership is reassigned.

## 2. P2 workflow-lint migration count — RESOLVED by Builder; current CI PASS

The previous lint hard-coded 27 migrations and failed with 32 actual files. Builder's current implementation at head `329a0be14d49f5c1c1f2efe5273495dda09f3b25`:
- discovers versioned migration filenames dynamically;
- checks unique, increasing four-digit versions;
- rejects SQL migration filenames that do not match the four-digit format;
- verifies the DB runner dynamically enumerates migration files and compares all discovered versions with `supabase_migrations.schema_migrations`.

GitHub Actions run 45846570698 ran `tests/workflow_lint.py`: 14/14 PASS. The clean DB reset applied all 32 migrations through 0033. No QA edit to `tests/workflow_lint.py` was needed.

## 3. Synthetic university dataset — MISSING IMPLEMENTATION

**Observed Builder head:** `329a0be14d49f5c1c1f2efe5273495dda09f3b25` (PR #41).

The required 20 STUDENT + 10 FACULTY + 10 synthetic platform-admin dataset is not present in the committed implementation inspected by QA.

Evidence:
- `fixtures/demo-profiles.json` has four GRADUATE demo accounts only.
- `scripts/provision-demo-users.mjs` iterates only `demo-profiles.json`; it creates those four graduate users, not student/faculty/admin university accounts.
- `scripts/build-seed.mjs` produces `01_skills.sql`, `02_catalogue.sql`, `03_demo_profiles.sql`; there is no university identity/GPA/track seed.
- `supabase/seed/03_demo_profiles.sql` updates graduate profile, skills, career history, sample applications and registrations.
- Migration 0028 permits human identity types `STUDENT`, `GRADUATE`, `FACULTY` only. `ADMIN` is not a valid human identity.
- `scripts/bootstrap-platform-admin.mjs` is a one-time first-admin bootstrap for one confirmed Auth account; it is not a local ten-admin seed.

**Required Builder implementation before QA can build tests:** commit the actual fixture, field vocabulary, GPA scale/constraints, track vocabulary, student/faculty identity attributes, admin membership provisioning contract, local provisioning script, idempotency policy, and documentation. Do not infer these fields from QA or change the schema on the QA branch.

**Security/local-only note:** `scripts/provision-demo-users.mjs` accepts `SUPABASE_URL` and service-role credentials but does not enforce a local-host allow-list itself. Its existing local-runner caller is local, but direct script invocation is not independently protected. Add an explicit allow-list check before the first HTTP request and unit tests for supported local URLs, hosted URLs, deceptive hostnames/userinfo/query tricks, and malformed URLs. Do not log or commit the service-role key.

**Acceptance to test after implementation:** 20 STUDENT, 10 FACULTY, 10 private.platform_admins accounts plus four preserved GRADUATE demos; no duplicate references/phone/identity/profile/admin membership after two runs; synthetic source markers; no ADMIN human identity; student-only/faculty-only rows without graduate profiles; GPA scale/range/uniqueness; documented tracks; faculty attributes; RLS/privacy; admin privilege escalation denial; local-only guard; counts unchanged after second run.

## 4. QA evidence: latest Builder baseline

Run 45846570698: https://github.com/imo-foad/graduate_Project/actions/runs/45846570698

- npm: 143/143 PASS
- OpenAPI: 24/24 PASS
- Workflow lint: 14/14 PASS
- 32 migrations applied on clean local Supabase
- seed loop: 50 skills and 21 opportunities, second pass idempotent
- pgTAP: 18 files / 658 assertions, only Test 15 assertion 16 failed (10 active vs 11 total TRAINING rows)
- Tests 01, 02, 16 and 19 reported OK on the Builder-head test versions.
- Concurrency and local HTTP integrations were not reached because pgTAP failed.

Artifact: https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15131653447/zip (database-test-logs; contains reset, pgTAP, container, Docker and environment logs). No concurrency/HTTP log exists because those stages did not execute.

QA corrected Test 15 by setting `is_sample=false` in `tests.mk_opp`, retaining the 11-row total in the test transaction (7 seeded + 4 test fixtures), and separately asserting the seven sample catalogue rows remain active. QA also added Test 01 candidate/system status-history assertions and an independently logged Test 15 preflight. These QA changes still require a fresh post-sync CI run.

## 5. External provider blockers

Real institutional identity API and SMS/OTP delivery are `BLOCKED_EXTERNAL` until approved provider contracts, credentials and configuration are available. Continue using deterministic local mocks only in disposable local Supabase; do not claim mock coverage as real provider delivery.
