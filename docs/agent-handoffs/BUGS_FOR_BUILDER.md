# Builder Handoffs — Independent QA

## 1. P1 — E.164 registration retry lookup

**Status:** Original defect reproduced; current Builder code corrected; final local-DB runtime proof still pending.  
**Original affected functions:**
- public.find_pending_registration_retry(text,text) in migration 0030
- public.find_unlinked_pending_registration_retry(text) in migration 0031
- caller: supabase/functions/register/index.ts

At Builder commit a522b01d6b0e7f27ed1a82e8ae1680aa05ccb1a2, both SQL functions used two literal backslashes before + in the E.164 regex. In PostgreSQL ARE syntax, \\ matches a literal backslash and + repeats the preceding atom. A normal leading-plus phone therefore failed validation. register/index.ts called the first lookup before provider verification/Auth-user creation and mapped the SQL error to HTTP 503 REGISTRATION_RETRY_UNAVAILABLE. Builder CI 45829327113 later ran test 19 and observed INVALID_INPUT from the lookup when supplied a valid synthetic E.164 number.

**Current Builder code:** Commit ec7c62e94aa4ec6e24160f72dafe9bf5ff9e6593 rewrote the functions in migrations 0030/0031 and now uses ^[+][1-9][0-9]{7,14}$ in both. The function delimiters and validation blocks are now structurally well formed. Intermediate commit 4c923fef115e70666c7cd5fd720e98151e0be1a0 briefly contained a malformed SQL rewrite and failed the static SQL structure check; that version was superseded by ec7c.

CI 45830300439 on ec7c passed npm/static SQL structure checks but its local database job was cancelled after a newer push, before test 19 runtime verification. The current Builder Edge Function also enforces that the synthetic identity provider can only be used when ALLOW_MOCK_IDENTITY=true and SUPABASE_URL is an HTTP local Supabase host.

**Reproduction against the original defect** (disposable local Supabase with matching pending fixtures; service_role):

```sql
select public.find_pending_registration_retry('+201011110001', repeat('e', 64));
select public.find_unlinked_pending_registration_retry('+201011110002');
```

Expected on current code: valid E.164 values pass validation and exact eligible lookups return the pending profile UUID (or NULL if no matching eligible row exists). Historical actual: PT422 INVALID_INPUT.

**Closure evidence still required:** Complete the official disposable-local-Supabase runner on the latest Builder code and confirm test 19 is visibly executed with its positive valid-phone assertions passing. The latest observed Builder database job has not completed at the time of this report. QA did not modify migrations 0030/0031, register/index.ts, or test 19.

## 2. P2 — Workflow lint hard-codes obsolete migration count

**Status:** Reproduced in GitHub Actions; unresolved.  
**File:** tests/workflow_lint.py  
**Test:** Scripts.test_run_script_covers_all_phases_and_migrations (line 95).

Builder CI run 45831195333 on commit ffd02350b6280e5ea0672fa6a3333587d0773513 reports:

```
self.assertEqual(len(migs), 27)
AssertionError: 32 != 27
Ran 14 tests
FAILED (failures=1)
```

The repository contains 32 migration files through 0033, while the test embeds a fixed count of 27 and a hard-coded list ending at 0028.

**Expected:** Validate required historical migrations and approved ordering, while discovering all forward migration files dynamically rather than freezing a count/terminal version.  
**Actual:** The valid forward migrations cause workflow lint to fail.

**Suggested correction:** Derive the complete migration set/order from the repository and runner, then assert every migration is applied by the official runner. Preserve missing-file and ordering checks; do not skip or suppress the test.

**Ownership:** tests/workflow_lint.py is outside Agent 2's explicit owned-file list. QA documents the finding but does not edit it; Builder/maintainer should assign the harness correction.
