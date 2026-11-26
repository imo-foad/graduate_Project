# Alumni Connect AI — Full Repository Test & Audit

**Audit date:** 2026-11-24  
**Repository:** `imo-foad/graduate_Project` (private)  
**Review branch:** `fix/postgres-runtime-test-failures`  
**Pull request:** [#2 — PostgreSQL and Storage test fixes](https://github.com/imo-foad/graduate_Project/pull/2)

## Scope and safety

The pre-audit snapshot is preserved on `backup/pre-full-audit-2026-11-24` at `08d5af2f4ca6aefb03073c22bf2972793b647d5c` (51 tracked files). The current review branch contains **55 tracked files** across application code, config, documentation, fixtures, scripts, migrations, seeds and test suites.

All changes are isolated on `fix/postgres-runtime-test-failures`; PR #2 targets `backend-initial-import`. `main` has not been changed. No Supabase Cloud project has been linked, reset, migrated or modified. All live integration checks use a disposable local Supabase stack in GitHub Actions.

## Latest full test result

[GitHub Actions run #67](https://github.com/imo-foad/graduate_Project/actions/runs/45416127368) completed successfully on commit `1a8ae70164034690af9722f2c7de6fb43943e3f1`.

| Test group | Result |
|---|---:|
| Node / TypeScript | 75 / 75 passed |
| OpenAPI contract | 18 / 18 passed |
| Workflow lint | 12 / 12 passed |
| PostgreSQL migrations | 10 / 10 applied |
| pgTAP | 204 / 204 passed across five files |
| Concurrency | 21 / 21 checks passed |
| Local HTTP integration | 22 / 22 checks passed |
| **Total counted automated checks** | **352 / 352 passed** |

The total is the sum of the six assertion-based suites above (75 + 18 + 12 + 204 + 21 + 22). Additional setup and seed-integrity guards ran successfully but are not double-counted in that total.

Runtime evidence: PostgreSQL 17.12 and Supabase CLI 3.3.0. Migrations 0001–0010 applied in order. Catalogue seeds were run twice; idempotency and foreign-key reference checks passed with 50 skills and 29 opportunities. All 21 concurrency checks passed, covering capacity/waitlist races, duplicate registration, concurrent applications, stale recommendation snapshots, dirty-flag protection and competing recommendation saves.

## Newly covered integration tests

### Auth and demo profiles

- The local Supabase Auth Admin API provisioned all four synthetic demo users. The provisioning script was executed twice to check that existing users are handled idempotently.
- The Auth trigger created four corresponding rows in `profiles` and four rows in `graduate_profiles`.
- `supabase/seed/03_demo_profiles.sql` was applied twice. Counts remained stable: 17 seeded skill rows, 3 sample applications and 3 sample history records.
- Two demo users successfully completed the password-grant login over HTTP.

### Storage and CV metadata

The test uploads a PDF through the real local Storage HTTP API, inserts a `cv_documents` metadata record, and verifies:
- Owner can upload/read/delete their own object and delete their own metadata.
- Another graduate cannot read the private object or metadata.
- Another graduate cannot upload into the owner's folder or delete the owner's object.
- The object remains available to its owner after the unauthorized delete attempt.

The pgTAP Storage test separately verifies Supabase's direct-SQL deletion guard (SQLSTATE `42501`) and owner-folder policy.

**Scope boundary:** CV document parsing/extraction is not an implemented HTTP endpoint yet. These tests prove upload/storage ownership and metadata handling, not parsing correctness.

### Recommendation Edge Function

The actual `recommend` Edge Function was served through the disposable local Supabase gateway and exercised over HTTP with JWT verification enabled. Tests verified:
- GET is rejected; missing and invalid JWTs are rejected.
- Two separate users can independently compute recommendations.
- The next request for the first user serves the cached result.
- `force=true` causes recomputation.
- Recommendation rows exposed through PostgREST are scoped to the authenticated graduate.

## Subsystem scores

Scores below are engineering-readiness judgments, not a code-coverage percentage. They consider both the successful tests and the limitations explicitly listed in this report.

| Subsystem | Score / 100 | Assessment |
|---|---:|---|
| Database schema and migrations | 98 | All ten migrations applied on PostgreSQL 17.12; clean reset and pgTAP passed. No cloud upgrade rehearsal. |
| RLS and database permissions | 98 | pgTAP and cross-user HTTP tests passed; the policy helper is private-schema only. No independent penetration test. |
| RPCs and business rules | 96 | RPC rules, eligibility, ownership and concurrency tests passed. A2/A3 business assumptions still need owner confirmation. |
| Concurrency and recommendation cache | 100 | All 21 real concurrent-session checks passed. |
| API / OpenAPI contract | 96 | All 18 contract tests passed; recommend Edge Function exercised over local HTTP. No production deployment rehearsal. |
| Storage and CV metadata | 96 | Private Storage upload/read/delete and cross-user denial passed over HTTP. CV parsing itself is not implemented. |
| Auth, demo users and demo seed | 98 | Four demo users provisioned, trigger-created profiles checked, demo seed applied twice and logins verified. |
| Recommendation and scoring | 95 | Function HTTP behavior and cache/RLS tested. Semantic quality still depends on lexical proxy assumptions B1–B6. |
| CI and test automation | 100 | Static, SQL, concurrency and local HTTP jobs pass; CLI version is pinned and cleanup is bounded. |
| Documentation and Android contract | 95 | OpenAPI and Android integration checks pass; CV parsing and A2/A3 business decisions remain outside the verified contract. |
| **Overall engineering readiness** | **97** | Strong verified local backend core; remaining points are product/quality and deployment assurance gaps, not failing CI tests. |

The overall score is the rounded mean of the ten subsystem scores.

## Findings and fixes

### Migration 0008 — scalar-to-array runtime bug

`supabase/migrations/0008_fix_array_appends.sql` replaces ambiguous scalar concatenation with `array_append()` in the final `eligibility_failures()` and `get_my_insights()` definitions. This fixes the malformed array-literal runtime errors found in the earlier PostgreSQL test.

### Migrations 0009–0010 — RLS recursion and private helper

The original RLS failure was a recursive dependency between the opportunity catalogue SELECT policy and saved-opportunity INSERT policy. Migration 0009 now uses a narrowly scoped SECURITY DEFINER existence predicate inside the non-exposed `private` schema, retaining the `graduate_id = auth.uid()` ownership check. Migration 0010 is a compatibility cleanup for databases that may have applied an earlier public-helper draft. Both migrations passed in run #67.

### CI / HTTP integration runner

The database job now runs after migrations, seeds, pgTAP and concurrency:
- Local Auth Admin provisioning and demo profile seed idempotency.
- Local HTTP calls to the recommendation Edge Function.
- Real Storage HTTP API upload/read/delete and cross-user denial.
- Bounded per-request and whole-suite timeouts.
- Local URL validation before provisioning or API operations.
- Bounded Supabase cleanup and an isolated workflow concurrency group.

The CI runner pins Supabase CLI 3.3.0 and does not use cloud credentials or perform cloud deployments.

## Remaining gaps (not CI failures)

1. **CV parsing:** parsing/extraction is not yet available as a backend endpoint. Current end-to-end coverage ends at upload, ownership and CV metadata.
2. **Scoring quality:** the semantic similarity component is a lexical proxy rather than embeddings. It needs evaluation against a labeled recommendation dataset before making quality claims.
3. **Business requirements:** assumptions A2 (INTERNSHIP application eligibility) and A3 (TRAINING registration eligibility) still need product-owner confirmation.
4. **Security assurance:** automated local RLS and Storage tests passed, but this is not a third-party security audit or penetration test.
5. **Production rehearsal:** no production/cloud project was linked or modified. Production configuration, secrets and rollout still require a separately reviewed deployment plan.
6. **Push notifications:** FCM is not implemented; notifications are in-app only and this remains outside the current backend scope.

## Final status

**All 352 counted automated checks passed on run #67**, including the new Auth/demo-seed, Storage HTTP and recommendation Edge Function HTTP integration tests. The current branch is green for the automated local backend test scope described here. Remaining items are unimplemented product capabilities or external assurance/release tasks, not current CI failures.

## Branches and evidence

- Snapshot: `backup/pre-full-audit-2026-11-24`
- Active review branch: `fix/postgres-runtime-test-failures`
- Review PR: [#2](https://github.com/imo-foad/graduate_Project/pull/2)
- Full green CI: [run #67](https://github.com/imo-foad/graduate_Project/actions/runs/45416127368)

---

## Addendum — 2026-11-26: product scope alignment (Scholarship/Competition cancelled)

Branch: `fix/alumni-connect-scope-alignment`. This addendum is deliberately separate from the historical
snapshot above, which describes an older branch and must not be read as current evidence.

**Product decision applied:** Scholarship (issue #14) and Competition (issue #15) are cancelled product
lines. Nothing from those lines is part of the active backend contract.

**What changed (additive, no historical migration edited):**

| Area | Change | Evidence |
|---|---|---|
| Database | `0025_cancel_scholarship_and_competition.sql`: scope predicate, insert guard, existing rows set to `CANCELLED`, cancelled types removed from the candidate projection and from RLS discovery, client grants revoked on applicant tables and on every scholarship/competition routine | `supabase/tests/database/10_cancelled_scope_guard.test.sql` |
| Recommendations | Cancelled types are never scored; model version `deterministic-v5-scope-aligned` forces recomputation; cached rows of cancelled types are deleted | `tests/scoring.test.ts`, `tests/opportunity-state.test.ts` |
| API surface | Scholarship Edge Functions, shared provider modules, OpenAPI paths/schemas and Android documentation removed | `tests/contract_openapi.py` |
| Seed/fixtures | Sample `SCHOLARSHIP` and `COMPETITION` rows removed (29 → 27 opportunities) | `scripts/build-seed.mjs` output, seed assertions |
| CI diagnostics (#21) | `.ci-logs/` artifact now uploads with `include-hidden-files: true`, fixing the repeated "No files were found" warning | `.github/workflows/backend-tests.yml` |

**Retained on purpose:** the four historical applicant tables and their RLS policies, migrations
`0015`/`0016`/`0020`/`0021`, and all historical rows. They are readable only by `service_role`; no client
endpoint exposes them. Deleting them would destroy data and break foreign keys, so they stay.

**Known limitations introduced by the product decision, not by this change:** Student/Faculty/Organization/
Institution identities, national-ID registration and institutional database verification are still absent from
the backend; `README.md` states this explicitly. They are not claimed as delivered.
