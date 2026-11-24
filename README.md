# Alumni Connect AI — Backend (v0.1, phases 1–4 + scoring core)

Supabase-first backend (Postgres + Auth + private Storage + Edge Functions). Graduate is the only account type.
All data is synthetic. Android is a separate workstream: see `docs/openapi.yaml` and `docs/ANDROID_INTEGRATION.md`.

## Architecture decision

Supabase (free plan) with no separate server: relational integrity, RLS and race-sensitive operations live in
Postgres (RPCs with row locks); the only Edge Function is `recommend` (deterministic scoring, no paid AI).
Free-plan figures seen in third-party sources (500 MB DB, 1 GB storage, 500k function invocations, pause after
7 days idle) are **not verified against supabase.com/pricing** — check before relying on them.

## Layout

- `supabase/migrations/0001..0010` — schema, catalogue, activity, RPCs, grants/RLS/storage bucket and audit/security fixes
- `fixtures/*.json` -> `npm run build:seed` -> `supabase/seed/01_skills.sql, 02_catalogue.sql, 03_demo_profiles.sql`
- `supabase/functions/_shared/` — deterministic scoring, opportunity filtering and recommendation orchestration
- `supabase/functions/recommend/` — authenticated Edge Function
- `scripts/provision-demo-users.mjs` — creates four synthetic demo Auth users (public sign-up stays disabled)
- `scripts/run-local-integrations.sh` — local-only Auth, demo-seed, Storage and Edge HTTP checks
- `tests/` — Node, OpenAPI, workflow, SQL, pgTAP and HTTP integration tests

## Full verification status (2026-11-24)

<https://github.com/imo-foad/graduate_Project/actions/runs/45416127368> — GitHub Actions **run #67**, successful on commit `1a8ae70164034690af9722f2c7de6fb43943e3f1`.

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

Additional database/runtime evidence:
- PostgreSQL 17.12; Supabase CLI pinned to 3.3.0.
- All ten migrations applied in a clean disposable local Supabase stack.
- Catalogue seed idempotency: 50 skills and 29 opportunities loaded twice.
- Four demo Auth users provisioned; four trigger-created graduate profiles verified.
- `03_demo_profiles.sql` applied twice and checked for stable sample rows: 17 seeded skills, 3 sample applications and 3 sample history records.
- Recommendation Edge Function exercised through the local HTTP gateway with JWT checks, user separation, cache hit, force recomputation and method/auth rejection.
- Storage HTTP API exercised for own upload/read/delete and cross-user read/upload/delete denial.
- No Supabase Cloud project was linked, reset or modified.

## Remaining product / security limitations

- **CV parsing is not implemented as an endpoint yet.** The completed HTTP tests cover private file upload, ownership, CV metadata and deletion; they do not claim to test document parsing.
- Recommendation matching is deterministic; its lexical similarity is a proxy, not an embedding model. Assumptions B1–B6 need calibration against a labeled dataset.
- Business assumptions A2 (INTERNSHIP application eligibility) and A3 (TRAINING registration eligibility) still need product-owner confirmation.
- Automated local RLS/Storage tests are not a third-party penetration test or a production-cloud deployment rehearsal.
- FCM push notifications remain out of scope; notifications are in-app only.

See `docs/AUDIT_REPORT.md` for the subsystem scores, exact test evidence and remaining gaps.
