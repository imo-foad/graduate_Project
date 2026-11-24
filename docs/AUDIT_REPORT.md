# Alumni Connect AI — Full Repository Test & Audit

**Audit date:** 2026-11-24  
**Repository:** `imo-foad/graduate_Project` (private)  
**Review branch:** `fix/postgres-runtime-test-failures`  
**Pull request:** [#2 — PostgreSQL and Storage test fixes](https://github.com/imo-foad/graduate_Project/pull/2)

## Scope and backup

The pre-audit snapshot is preserved on `backup/pre-full-audit-2026-11-24` at `08d5af2f4ca6aefb03073c22bf2972793b647d5c` (51 tracked files). The current review branch contains 53 tracked files across application code, config, docs, fixtures, scripts, migrations, seeds and tests.

All changes are isolated on `fix/postgres-runtime-test-failures`; PR #2 targets `backend-initial-import`. `main` has not been changed. No Cloud Supabase project has been linked, reset, migrated or modified.

## Latest full test result

<https://github.com/imo-foad/graduate_Project/actions/runs/45411332204> — GitHub Actions run **#53**, successful on commit `aefae8529778081626ea6cef10f57062ec5c01ec`.

| Area | Result |
|---|---:|
| Node / TypeScript | 74 / 74 passed |
| OpenAPI contract | 18 / 18 passed |
| Workflow lint | 11 / 11 passed |
| PostgreSQL migrations | 10 / 10 applied |
| pgTAP | 204 / 204 passed across five files |
| Concurrency | 21 / 21 checks passed |
| **Total automated assertions/checks** | **328 / 328 passed** |

Runtime evidence: PostgreSQL 17.12, Supabase CLI 3.3.0. Migrations 0001–0010 applied in order. Catalogue seeds were run twice; idempotency and reference checks passed with 50 skills and 29 opportunities. The concurrency script passed registration capacity and waitlist races, duplicate registration, concurrent applications, stale recommendation snapshots, dirty-flag protection, and competing recommendation saves.

## Subsystem scores

These are engineering-readiness scores, not a tool-generated coverage percentage. They combine actual test results with the scope of each test and the remaining unverified integrations.

| Subsystem | Score / 100 | Assessment |
|---|---:|---|
| Database schema and migrations | 98 | All 10 migrations applied on PostgreSQL 17.12; pgTAP passed. No cloud upgrade rehearsal. |
| RLS and database permissions | 98 | RLS isolation and write-denial tests passed; helper is private-schema only. No independent penetration test. |
| RPCs and business rules | 96 | RPC pgTAP and concurrency tests passed. A2/A3 business assumptions still need owner confirmation. |
| Concurrency and recommendation cache | 100 | 21/21 concurrent checks passed, including capacity and stale-snapshot races. |
| API / OpenAPI contract | 94 | 18/18 contract checks passed; no live PostgREST/Edge HTTP deployment test. |
| Storage and CV | 82 | Private bucket, ownership policies and SQL protection are tested; Storage API upload/delete E2E is absent and CV flow is not wired end-to-end. |
| Recommendation and scoring | 88 | Unit, flow and database cache tests pass; semantic score is a lexical proxy and assumptions B1–B6 need evaluation data. |
| Fixtures, seeds and demo Auth | 82 | Skills/catalogue seeds pass idempotency; demo profile SQL and Auth user provisioning are not executed end-to-end by CI. |
| CI and test automation | 100 | Both static and real database jobs passed; CLI version is pinned. |
| Documentation and Android integration | 93 | OpenAPI/Android contract tests pass; business-rule assumptions are still flagged. |
| **Overall engineering readiness** | **93** | Strong verified database core, with clear integration/quality gaps listed below. |

The overall score is the rounded mean of the ten subsystem scores.

## Findings and fixes

### Migration 0008 — scalar-to-array bug

`supabase/migrations/0008_fix_array_appends.sql` replaces ambiguous scalar concatenation with `array_append()` in the final `eligibility_failures()` and `get_my_insights()` definitions. This addresses the malformed array-literal error in the earlier real database run.

### Migrations 0009–0010 — RLS recursion and private helper

The original RLS failure was a recursive dependency between the opportunity catalogue SELECT policy and saved-opportunity INSERT policy. The policy now calls a narrowly scoped SECURITY DEFINER existence predicate that bypasses the recursive catalogue RLS path while retaining the `graduate_id = auth.uid()` ownership check.

Migration 0009 creates the helper in the `private` schema from the outset, avoiding exposure as a public PostgREST RPC. Migration 0010 is a compatibility cleanup: it drops any legacy public helper, reasserts private schema/function permissions, and recreates the policy against the private function. Both migrations passed in run #53.

### Storage

Supabase blocks direct SQL deletion from `storage.objects` with SQLSTATE `42501`. The pgTAP test asserts that protection and inspects the owner-folder DELETE policy. It does not call the Storage HTTP API to upload and delete an object. That end-to-end check remains outstanding.

## Remaining gaps (not CI failures)

1. **Storage API E2E:** test authenticated upload, own-object deletion, and denial of another user's deletion through the Storage API.
2. **Demo profile/Auth E2E:** run `scripts/provision-demo-users.mjs` against local Supabase Auth and execute `supabase/seed/03_demo_profiles.sql` in a disposable environment.
3. **Edge Function E2E:** deploy/serve `recommend` locally and exercise authorization, request validation, cache hits, recomputation and error responses over HTTP.
4. **Scoring calibration:** the semantic component is a lexical proxy rather than embeddings; evaluate it with a labeled recommendation dataset.
5. **Business requirements:** assumptions A2 (INTERNSHIP application eligibility) and A3 (TRAINING registration eligibility) remain product-owner decisions.
6. **Security assurance:** automated RLS tests passed, but this is not a third-party security review or penetration test.

## Final status

**All 328 automated checks passed on run #53**, including the final private-helper migration. The current branch is green for its implemented SQL, static contracts and concurrency runner. The remaining items are integration/quality gaps that are not currently covered by the automated CI suite, not failing tests.

## Branches and evidence

- Snapshot: `backup/pre-full-audit-2026-11-24`
- Active review branch: `fix/postgres-runtime-test-failures`
- Review PR: [#2](https://github.com/imo-foad/graduate_Project/pull/2)
- Full green CI: [run #53](https://github.com/imo-foad/graduate_Project/actions/runs/45411332204)
