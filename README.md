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

## Full verification status (2026-11-24)

<https://github.com/imo-foad/graduate_Project/actions/runs/45411332204> — run #53, successful on commit `aefae8529778081626ea6cef10f57062ec5c01ec`.

- Static: 74/74 Node/TypeScript, 18/18 OpenAPI contract, 11/11 workflow lint.
- PostgreSQL 17.12: all 10 migrations applied in order.
- Seeds: 50 skills and 29 opportunities loaded twice; idempotency and reference checks passed.
- pgTAP: all five files passed, 204 assertions.
- Concurrency: all 21 checks passed, including capacity/waitlist races, double-click registration, concurrent applications, stale recommendation snapshots and competing cache writes.
- Supabase CLI pinned to 3.3.0.
- No Supabase Cloud project was linked, reset or modified.

## Remaining integration gaps

- Storage authorization is tested in SQL, but upload/delete through the HTTP Storage API is not yet tested end-to-end.
- `03_demo_profiles.sql` is generated and statically tested, but the DB runner does not apply it or provision demo Auth users.
- The recommend Edge Function is unit/contract tested, not deployed and exercised over HTTP in CI.
- Recommendation semantic matching is a documented lexical proxy; assumptions B1–B6 need calibration against a real evaluation set.
- Business assumptions A2 (INTERNSHIP application eligibility) and A3 (TRAINING registration eligibility) require confirmation.

See `docs/AUDIT_REPORT.md` for subsystem scores and the full audit.
