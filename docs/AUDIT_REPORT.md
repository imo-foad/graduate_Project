# Alumni Connect AI — Full Repository Test & Audit

**Audit date:** 2026-11-24  
**Repository:** `imo-foad/graduate_Project` (private)  
**Review branch:** `fix/postgres-runtime-test-failures`  
**Pull request:** [#2 — PostgreSQL and Storage test fixes](https://github.com/imo-foad/graduate_Project/pull/2)

## Snapshot and safety

The pre-audit snapshot is preserved on `backup/pre-full-audit-2026-11-24` at `08d5af2f4ca6aefb03073c22bf2972793b647d5c` (51 tracked files). The current reviewed branch has 53 tracked files.

All work is isolated on `fix/postgres-runtime-test-failures`; PR #2 targets `backend-initial-import`. The `main` branch has not been changed. No Cloud Supabase project has been linked, reset, migrated or modified.

## Full green test evidence — run #52

[GitHub Actions run #52](https://github.com/imo-foad/graduate_Project/actions/runs/45410157487) completed successfully on commit `f9508073fa1bc65b11fe0627a8757376a3f7bb7c`.

| Test group | Result |
|---|---:|
| Node / TypeScript | 74 / 74 passed |
| OpenAPI contract | 18 / 18 passed |
| Workflow lint | 11 / 11 passed |
| PostgreSQL migrations | 10 / 10 applied |
| pgTAP | 204 / 204 passed across five files |
| Concurrency checks | 21 / 21 passed |

Runtime environment: PostgreSQL 17.12; Supabase CLI 3.3.0. Catalogue seeds loaded twice and passed idempotency: 50 skills, 29 opportunities, no orphan opportunity-skill references. The real concurrency suite passed capacity and waitlist races, duplicate registration, concurrent applications, stale recommendation snapshots, dirty-flag handling and competing recommendation saves.

## Confirmed issues and fixes

### Migration 0008 — scalar-to-array bug

`supabase/migrations/0008_fix_array_appends.sql` replaces ambiguous scalar concatenation with `array_append()` in the final `eligibility_failures()` and `get_my_insights()` definitions. This fixed the malformed array literal runtime errors.

### Migrations 0009–0010 — RLS recursion and helper exposure

The original failure was an RLS recursion between the opportunity catalogue SELECT policy and saved-opportunity INSERT policy. The fix uses a narrowly scoped SECURITY DEFINER predicate to check opportunity existence without recursively evaluating the catalogue policy.

A security review identified that an earlier draft placed this helper in `public`, which would expose it as a PostgREST RPC. The current hardening update changes migration 0009 to create it inside `private` from the outset. Migration 0010 remains an idempotent compatibility cleanup: it drops any legacy public helper, reasserts the private helper grants and policy, and ensures existing pre-review databases are cleaned up.

Run #52 passed migrations 0009 and 0010, pgTAP RLS tests and saved-opportunity ownership checks before this final adjustment to migration 0009. The branch must rerun CI after the adjustment to confirm the private-helper definition from the first migration still passes.

### Storage test limitation

Supabase rejects direct SQL deletion from `storage.objects` with SQLSTATE `42501`. The test now asserts that protection and checks the owner-folder DELETE policy. It does **not** perform an HTTP Storage API delete of an uploaded object; API-level upload/delete still requires a separate integration test.

## Inventory and quality limitations

- 53 tracked files across docs/OpenAPI, configuration, fixtures, scripts, Edge Function source, ten migrations, three generated seed files, five pgTAP files and static tests.
- Fixtures: 50 unique skill IDs, 29 unique opportunity seed keys across eight opportunity types, and four demo profiles with unique emails.
- The scoring implementation documents assumptions B1–B6. Its lexical similarity is a proxy, not an embedding model; treat score quality as a product-quality limitation, not a runtime failure.
- Business assumptions about INTERNSHIP application eligibility and TRAINING registration eligibility still need product-owner confirmation.
- The CI runner loads `01_skills.sql` and `02_catalogue.sql` twice. It generates but does not apply `03_demo_profiles.sql`, because that requires provisioned Auth users. Provisioning and Auth integration have static request tests, not live HTTP integration tests.
- The recommend Edge Function is unit-tested through injected dependencies and static contract checks; it is not deployed and exercised over HTTP in this CI workflow.
- Storage API end-to-end upload/delete test remains outstanding.
- Supabase CLI is pinned to 3.3.0 based on the green run rather than using `latest`.
- README Node engine requirement matches package.json (Node >= 22.6).

## Final verification status

Run #52 proved the ten-migration branch and all static, pgTAP and concurrency suites green. The current branch makes one additional hardening change to migration 0009 and pins the already verified CLI version. A fresh full run on the updated branch is required before the updated source is considered green.

## Branches

- Snapshot: `backup/pre-full-audit-2026-11-24`
- Active review branch: `fix/postgres-runtime-test-failures`
- Review PR: [#2](https://github.com/imo-foad/graduate_Project/pull/2)
- Prior full-green evidence: [Actions run #52](https://github.com/imo-foad/graduate_Project/actions/runs/45410157487)
