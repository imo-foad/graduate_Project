# Alumni Connect AI — Backend (v0.1, phases 1–4 + scoring core)

Supabase-first backend (Postgres + Auth + private Storage + Edge Functions). Graduate is the only account type.
All data is synthetic. Android is a separate workstream: see `docs/openapi.yaml` and `docs/ANDROID_INTEGRATION.md`.

## Architecture decision
Supabase (free plan) with no separate server: relational integrity, RLS and race-sensitive operations live in
Postgres (RPCs with row locks); the only Edge Function is `recommend` (deterministic scoring, no paid AI).
Free-plan figures seen in third-party sources (500 MB DB, 1 GB storage, 500k function invocations, pause after
7 days idle) are **not verified against supabase.com/pricing** — check before relying on them.

## Layout
- `supabase/migrations/0001..0010` — schema, catalogue, activity, RPCs, grants/RLS/storage bucket, audit fixes (0006), recommendation cache integrity + profile_version (0007)
- `fixtures/*.json` -> `npm run build:seed` -> `supabase/seed/01_skills.sql, 02_catalogue.sql, 03_demo_profiles.sql`
- `supabase/functions/_shared/` — `scoring.ts` (weights from doc 6.5), `cv-extract.ts`; `recommend/` Edge Function
- `scripts/provision-demo-users.mjs` — creates the 4 demo Auth users (no public sign-up)
- `tests/` — `npm test` (Node >= 22.18, no dependencies)

## Local run (needs Supabase CLI + Docker; NOT run in the authoring workspace)
```
supabase start                       # applies migrations
npm run build:seed
export SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... DEMO_PASSWORD=...   # see .env.example
node scripts/provision-demo-users.mjs
psql "$DB_URL" -f supabase/seed/01_skills.sql -f supabase/seed/02_catalogue.sql -f supabase/seed/03_demo_profiles.sql
supabase functions serve recommend
```
Cloud: `supabase link` to the **exact** project, review `supabase db push --dry-run`, then push. Never reset a remote DB.

## Runtime verification (2026-11-24)

- GitHub Actions run #17 applied migrations 0001–0008, loaded the catalogue seeds, and executed all five pgTAP files (203 assertions).
- That run reported 200 passing assertions and 3 failures:
  - Two RLS tests exposed infinite recursion between the saved-opportunity INSERT policy and catalogue SELECT policy. Migration 0009 replaces the recursive lookup with a narrowly scoped SECURITY DEFINER existence check.
  - One Storage test expected SQLSTATE P0001, but Supabase correctly returned 42501 because direct SQL deletion from Storage tables is protected. The test now expects 42501 and checks the owner-folder DELETE policy in pg_policies.
- The same Actions run had one static test-fixture failure because it still expected the previous migration sequence. The fixture was updated for migration 0009.
- The concurrency suite did not run in that attempt because pgTAP failed first. Do not treat the backend as fully verified until a fresh workflow run passes both static and database jobs, including concurrency.
- No Supabase Cloud project was linked, reset, or modified. All database runtime checks use the disposable local Supabase stack in CI.

See `docs/AUDIT_REPORT.md` for the detailed findings and exact CI evidence.
