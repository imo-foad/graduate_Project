# Alumni Connect AI — Backend (v0.1, phases 1–4 + scoring core)

Supabase-first backend (Postgres + Auth + private Storage + Edge Functions). Graduate is the only account type.
All data is synthetic. Android is a separate workstream: see `docs/openapi.yaml` and `docs/ANDROID_INTEGRATION.md`.

## Architecture decision
Supabase (free plan) with no separate server: relational integrity, RLS and race-sensitive operations live in
Postgres (RPCs with row locks); the only Edge Function is `recommend` (deterministic scoring, no paid AI).
Free-plan figures seen in third-party sources (500 MB DB, 1 GB storage, 500k function invocations, pause after
7 days idle) are **not verified against supabase.com/pricing** — check before relying on them.

## Layout
- `supabase/migrations/0001..0007` — schema, catalogue, activity, RPCs, grants/RLS/storage bucket, audit fixes (0006), recommendation cache integrity + profile_version (0007)
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

## Verification status — see `docs/AUDIT_REPORT.md` (authoritative)
- **Executed here:** `npm test` (72), `npm run test:contract` (18), `npm run test:workflow` (11). Static / fake-based only.
- **Never executed (no PostgreSQL/Docker/Supabase CLI/GitHub Actions access in the authoring workspace):** migrations 0001–0007, seeds,
  pgTAP files 01–05, `tests/db/concurrency.sh`. **Status: BLOCKED** until `npm run test:db` (needs Docker, Supabase CLI, psql, Node)
  or the CI job `database` passes. The DB scripts only accept a local database URL (parsed host check) and reset the LOCAL database.

## Assumptions and flagged conflicts (owner may overrule)
- A1 hard eligibility = `opportunity_eligibility` (graduation year range, degrees, required certifications).
- A2 only `JOB` is appliable (doc 7.1); internships cannot be applied to. **Conflict-adjacent: confirm.**
- A3 `TRAINING` is registrable (doc 4.2 scenario) although 7.2 lists only EVENT/CONFERENCE/VOLUNTEER. **Conflict: confirm.**
- A4 re-registering after cancelling reuses the same row. A5 confirmed CV skill without level = level 1.
- A6 profile completion = 9 equal items. A7 for TRAINING/EVENT, `opportunity_skills` = skills developed.
- Catalogue status stays ACTIVE/CLOSED/EXPIRED/CANCELLED; the doc's separate event states (OPEN, ONGOING, ...) are derived from dates.
- Scoring: B1–B6 in `scoring.ts` (training weights, level->years map, lexical stand-in for embeddings, location heuristics).
  Known limitation: events/internships with few criteria can score 100; calibrate with the AI evaluation set (doc 13.4).
- Waitlist promotion after a cancellation is not specified in the source and is not implemented.

## Next phases
CV parsing function (text extraction + validated `cv_suggestions`), optional Gemini explanations/embeddings only after
re-checking current free quotas and data-use terms, recommendation notifications, DB-backed integration/RLS/concurrency
tests, seed expansion to the doc's target counts.
