# Builder Handoffs — Independent QA

## 1. P1 E.164 phone validation — implementation RESOLVED; boundary coverage OPEN

Implementation is corrected in migrations 0030/0031. Latest Builder Test 19 reported `ok` in run 45855098768. The validator uses `^[+][1-9][0-9]{7,14}$`.

Historical defect: registration retry lookup rejected valid leading-plus E.164 values and returned `INVALID_INPUT`. QA did not modify Builder migrations or Test 19.

Remaining Test 19 boundary coverage:
- valid 8-digit and 15-digit country-code subscriber forms;
- malformed string / whitespace / alphabetic input;
- missing '+';
- leading zero after '+';
- too-short and too-long numbers;
- both pending-registration and unlinked-pending-registration retry RPCs.

Expected malformed / too-short / too-long values raise `PT422 INVALID_INPUT`. Test 19 remains Builder-owned.

## 2. P2 workflow-lint fixed count — Builder implementation updated; latest 3dd CI did not reach lint

The prior lint assumed 27 migration files and failed with 32 actual files. Builder's current workflow-lint dynamically discovers four-digit version files, validates uniqueness and increasing version order, rejects malformed SQL filenames, and checks the complete migration set against the DB runner's `schema_migrations` ledger comparison.

The latest Builder run 45855098768 did **not** execute workflow lint because the preceding OpenAPI contract step failed. Previous run 45846570698 on the prior Builder head passed 14/14 workflow-lint tests. QA's owned `scripts/run-db-tests.sh` independently removes `-ge 22` and stale terminal-version comments and validates every discovered migration name, increasing unique version prefix, reset log application and ledger equality. Current synchronized QA CI is still required.

## 3. Synthetic university fixture validator — minimum track count is too weak

Builder head `3dd22f7f136a07a19d1933411fa6a49f66a58b51` added the actual dataset:
- 20 Student, 10 Faculty and 10 private platform-admin accounts;
- 20 distinct GPA values, scale 4.0, range 2.14–3.94;
- seven tracks in the committed fixture: 4/3/3/3/3/2/2;
- 40 unique synthetic phones and 30 unique student/faculty institutional references;
- four original graduate demo users remain part of the seed contract;
- no National ID, email or password appears in the fixture;
- admins contain no `identity_type`; migration still allows only STUDENT/GRADUATE/FACULTY human identity types.

**Defect:** `scripts/build-seed.mjs::validateUniversityFixtures` currently uses `if(tracks.size<2)`, which permits only 2, 3 or 4 distinct tracks even though the approved acceptance requires at least five. The current data has seven and passes QA's new independent minimum-five fixture check, but the validator itself must reject a 4-track clone. Please change the Builder-owned validator to require at least five distinct approved tracks and add a negative unit test reducing a clone to four tracks.

## 4. OpenAPI contract missing newly granted academic record tables

Latest Builder run 45855098768 failed:
`tests/contract_openapi.py::Contract.test_every_granted_table_capability_is_documented`, line 130:
`AssertionError: unexpectedly None : student_academic_records: granted but undocumented`.

Migration 0034 grants authenticated SELECT on:
- `public.student_academic_records`
- `public.faculty_academic_records`

The OpenAPI contract test correctly requires every authenticated table grant to have a documented PostgREST path, with no extra methods beyond actual grants. Update Builder-owned `docs/openapi.yaml` with GET-only paths and appropriate schemas for both tables; keep the test strict. Re-run `python3 -m unittest tests/contract_openapi.py -v` (currently 24 tests, one observed failure naming the Student table).

## 5. QA Test 15, Test 01 and Test 02 corrections pending execution

On latest Builder CI run 45855098768, the older Builder test versions failed:
- Test01 assertion 23: `WAITLISTED` vs obsolete expected `REGISTERED`;
- Test02 assertion 8: `NOT_APPLICATION_OPPORTUNITY` vs obsolete expected `NOT_A_JOB`;
- Test15 assertion 16: actual 10 vs expected 11.

QA branch fixes:
- Test01 now asserts FIFO and transactional status-history changes.
- Test02 asserts `NOT_APPLICATION_OPPORTUNITY`.
- Test15 helper explicitly writes `is_sample=false`, preserving seven seeded rows plus four test fixtures = eleven total, without a fake seed or weakened count.
- Test16 report checks `FAILED=1` before claim, then retry eligibility, claim, PROCESSING, and abandoned lease recovery separately.

These exact QA revisions require a new run after branch synchronization. No current green result is claimed.

## 6. Synthetic university provisioning and authorization — QA integration awaiting run

QA added `tests/integration/university-dataset.integration.mjs` and wired it after `seed-university-demo.mjs` in `scripts/run-local-integrations.sh`. It checks:
- 20/10/10 fixture counts, 20 distinct in-range GPAs and at least five approved tracks;
- phone/ref uniqueness and no email/National ID/password fixture fields;
- strict API and DB local-only URLs, including misleading hostnames/userinfo and hosted URLs;
- each synthetic phone Auth user is phone-only, confirmed and carries the seed marker;
- 20 VERIFIED STUDENT + 10 VERIFIED FACULTY identities, no ADMIN identity;
- no new synthetic user has a graduate profile;
- Student can read their own academic record but not another Student's or Faculty's;
- Faculty can read their own Faculty record but cannot read Student records;
- regular Student/Faculty cannot pass `assert_platform_admin` or grant themselves admin;
- one legitimate local synthetic admin passes the private platform-admin guard;
- authenticated users cannot insert academic records or self-assign a FACULTY identity;
- all four original graduate demos remain intact.

This new integration is not yet executed. The latest Builder pgTAP failure stopped the workflow before the HTTP stages. It must run against clean disposable local Supabase before these checks may be called passed.

The SQL seed runner `scripts/seed-university-demo.mjs` itself performs Auth provisioning twice (second run expects zero new and 40 reused), applies the SQL seed twice, and asserts exact dataset/profile counts. Latest Builder CI did not reach this step, so idempotency remains NOT RUN.

## 7. CV cleanup and other broad tests — execution status

On latest Builder run 45855098768, Test16 passed on Builder's version, as did recommendation availability Test17, identity Test18, and phone Test19. The current QA additions to Test16 and Tests01/02/15 still require execution.

Concurrency, local HTTP, CV Storage worker HTTP deletion/replacement behavior, onboarding, CV parser integration, rate limits and career-cohort rounds 1/2 were NOT REACHED because pgTAP failed. Do not claim those stages completed.

## 8. Local-only / external blockers

The new university provisioner uses an exact local API allow-list and DB URL guard before any provisioning or SQL write. The old graduate provisioner now calls the same API allow-list. No real National IDs are committed; Auth provisioning uses phone-only synthetic identities and service credentials only in server-side environment variables.

Real institutional provider API and SMS/OTP sending are `BLOCKED_EXTERNAL` until approved provider access is configured. Local deterministic mocks are not real integration evidence.

## Latest relevant CI links and artifact

Builder run 45855098768: https://github.com/imo-foad/graduate_Project/actions/runs/45855098768  
- npm: 149/149 PASS.
- OpenAPI: 24 run / 1 failure (missing `student_academic_records` docs).
- 33 migrations applied; seeds: 50 skills, 21 opportunities, idempotent.
- pgTAP: 18 files / 651 assertions; Test01, Test02, Test15 failed on old Builder assertions; Test16/Test19 passed.
- Concurrency and local HTTP not reached.

Artifact: https://api.github.com/repos/imo-foad/graduate_Project/actions/artifacts/15136086556/zip (`database-test-logs`; downloaded and inspected). Contains db reset, pgTAP, container, docker and Supabase environment logs.
