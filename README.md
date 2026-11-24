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
- `tests/` — `npm test` (Node >= 22.6, no dependencies)

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

Latest full green evidence before the final hardening pass: [GitHub Actions run #52](https://github.com/imo-foad/graduate_Project/actions/runs/45410157487).

- Static checks: 74/74 Node/TypeScript tests, 18/18 OpenAPI contract tests and 11/11 workflow tests passed.
- PostgreSQL 17.12 applied all ten migrations (0001–0010) successfully.
- Catalogue seeds loaded twice: 50 skills and 29 opportunities; idempotency and referential integrity checks passed.
- All five pgTAP files passed: 204 assertions.
- All concurrency checks passed: registration capacity and waitlist races, duplicate submissions, concurrent applications, and recommendation snapshot/cache races.
- The Storage pgTAP file verifies that direct SQL object deletion is blocked and that the delete policy is owner-folder scoped. It is not an HTTP Storage API upload/delete end-to-end test.
- The CI runner does not provision demo Auth users or execute `03_demo_profiles.sql`; those integration steps still need a separate local Auth verification.
- No Supabase Cloud project was linked, reset, or modified.

The current review branch has one additional security hardening change: migration 0009 now creates the RLS helper inside the private schema from the outset, rather than briefly exposing a helper in `public`. Migration 0010 remains as a compatibility cleanup for databases that applied an earlier public-helper version. This latest hardening pass must receive a fresh full CI run before the current branch is called fully green.

See `docs/AUDIT_REPORT.md` for the detailed evidence and limitations.
