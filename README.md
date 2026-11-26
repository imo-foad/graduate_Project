# Alumni Connect AI — Backend (v0.1, phases 1–4 + scoring core)

Supabase-first backend (Postgres + Auth + private Storage + Edge Functions).
All data is synthetic. Android is a separate workstream: see `docs/openapi.yaml` and `docs/ANDROID_INTEGRATION.md`.

## Product scope (2026-11-26)

Approved account scope: Student, Graduate and Faculty human accounts, plus Company, Organization and
Institution identities. **Implementation status:** graduate accounts are implemented end to end; company
identities exist as `companies` + `company_memberships` with owner/recruiter/viewer permissions. Student,
Faculty, Organization and Institution identity models, national-ID registration and institutional database
verification are **not implemented yet** — they are tracked as product work, not delivered by this branch.

Cancelled product lines (explicit product decision, not deprioritisation):

- **Scholarship (issue #14) — cancelled.** No submission, review, delivery, provider or recommendation flow.
- **Competition (issue #15) — cancelled.** No entry, capacity, waitlist or recommendation flow.
- **Out of scope:** tuition/fees, installments, financial assistance, lectures, exams, academic course content
  and university financial services.

Migration `0025_cancel_scholarship_and_competition.sql` deactivates both lines without deleting history:
`SCHOLARSHIP`/`COMPETITION` are inactive opportunity types (new rows rejected, existing rows set to
`CANCELLED`), their RPCs are revoked from `anon`/`authenticated` and the applicant tables are no longer
readable by clients. Historical rows remain for data integrity and are documented as such in
`docs/ANDROID_INTEGRATION.md`. Re-enabling either line requires a new, explicit product decision and a
forward migration.

## Architecture decision

Supabase (free plan) with no separate server: relational integrity, RLS and race-sensitive operations live in
Postgres (RPCs with row locks); the only Edge Function is `recommend` (deterministic scoring, no paid AI).
Free-plan figures seen in third-party sources (500 MB DB, 1 GB storage, 500k function invocations, pause after
7 days idle) are **not verified against supabase.com/pricing** — check before relying on them.

## Layout

- `supabase/migrations/0001..0025` — schema, catalogue, activity, RPCs, grants/RLS/storage, social feed, onboarding, recommendations and scope alignment
- `fixtures/*.json` -> `npm run build:seed` -> `supabase/seed/01_skills.sql, 02_catalogue.sql, 03_demo_profiles.sql`
- `supabase/functions/_shared/` — deterministic scoring, opportunity filtering and recommendation orchestration
- `supabase/functions/recommend/` — authenticated Edge Function
- `scripts/provision-demo-users.mjs` — creates four synthetic demo Auth users (public sign-up stays disabled)
- `scripts/run-local-integrations.sh` — local-only Auth, demo-seed, Storage and Edge HTTP checks
- `tests/` — Node, OpenAPI, workflow, SQL, pgTAP and HTTP integration tests

## Historical verification baseline (2026-11-24 — not current evidence)

The table below is the audit snapshot from 2026-11-24, kept for traceability. Current evidence for a change
lives in that branch's GitHub Actions run, not here.

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

- **CV parsing:** PDF/DOCX text extraction, dictionary-based skill extraction and section-rule extraction for work experience, certifications and courses are implemented. Structured items remain PENDING until the graduate reviews them with `review_cv_suggestions`. Scanned/image-only PDFs still need OCR and are not parsed by the free local parser.
- Recommendation matching is deterministic and explainable; inferred career paths use a local skill taxonomy, interaction signals affect ranking, mandatory experience can exclude a candidate, and market gaps are measured against active platform jobs. Lexical similarity remains a proxy, not an embedding model.
- Business assumptions A2 (INTERNSHIP application eligibility) and A3 (TRAINING registration eligibility) still need product-owner confirmation.
- Automated local RLS/Storage tests are not a third-party penetration test or a production-cloud deployment rehearsal.
- FCM push notifications remain out of scope; notifications are in-app only.

See `docs/AUDIT_REPORT.md` for the subsystem scores, exact test evidence and remaining gaps.


## Stage 3 — Career Profile Intelligence
- The authenticated `POST /functions/v1/recommend` response returns a deterministic `career_profile` built from the graduate's own confirmed skills.
- Paths cover Frontend, Backend, Mobile, Data Analytics, Data Science / ML, Cybersecurity, DevOps / Cloud, QA Automation and UI/UX.
- Core skills carry 3x the weight of supporting skills. A path needs at least two matched core skills; Backend, Data Science and Cybersecurity also require path-specific specialization evidence. Results include a primary path, every qualifying parallel path, weighted skill coverage, matched evidence, missing core skills, suggested next skills and an Arabic explanation.
- The score measures coverage of the defined path skill catalogue; it is not a hiring probability. Pending CV suggestions never contribute before graduate confirmation.
- The recommendation model version is `deterministic-v5-scope-aligned`; cached rows produced by an older model version are recomputed before being served.

## Free-first career intelligence (migration 0014)
- Structured CV suggestions now cover SKILL, EXPERIENCE, CERTIFICATION and COURSE. Extraction uses PDF.js/fflate plus local section/date rules; no paid API key or external model is needed.
- Review through `POST /rest/v1/rpc/review_cv_suggestions` with `p_decisions: [{id,status,payload?}]`. Only confirmed suggestions are written to `graduate_skills`, `career_history`, `certifications` or `courses`.
- `POST /rest/v1/rpc/get_career_market_insights` returns job-demand counts and skill gaps based only on active JOB/INTERNSHIP entries in this platform.
- `POST /rest/v1/rpc/record_recommendation_interaction` records IMPRESSION, VIEW, DISMISS or NOT_INTERESTED. Saves, job applications and event registrations are recorded automatically.
- Companies/admins can set a numeric minimum through `set_job_experience_requirement`; it can be mandatory (not recommended below threshold) or preferred (score penalty).
- Career paths and recommendation scoring are local deterministic TypeScript. pgvector/hosted LLMs are intentionally deferred to avoid paid infrastructure and CV data sharing.
