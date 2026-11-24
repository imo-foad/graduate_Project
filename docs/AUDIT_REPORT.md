# Backend runtime-verification task — Alumni Connect AI (v0.4)

## FINAL STATUS: **BLOCKED**
The first real PostgreSQL run **has not happened**. Blockers (verified, not assumed):
1. **No usable GitHub repository.** A GitHub search for the project returned only other people's public repos (none is this backend), so I could not identify a repository to push a branch to, and I did not guess one. There is also no tool available to me that triggers or reads GitHub Actions runs or logs (only branch/file/PR tools; PR check-runs would need a PR on a known repo).
2. **No local runtime.** In this workspace `supabase`, `psql`, `docker`, `deno`, `postgres` are all NOT FOUND and there is no network. `npm run test:db` was executed and stopped at its own preflight: `MISSING TOOL: supabase` (exit 3).

Consequently **no migration (0001–0007), seed, pgTAP file, RLS/Storage test or concurrency test has been executed on PostgreSQL**, and nothing below should be read as runtime proof of them. The Cloud Supabase project (`qikqbvohqjblbcysbvel`) was not touched in this task: no Supabase tool was called, no `apply_migration`, no branch, no link, and its URL is rejected by the new guard.

## A. Environment
| Item | Value | Source |
|---|---|---|
| GitHub runner OS / Docker / Supabase CLI / psql / PostgreSQL there | **NOT RUN** (no workflow run) | — |
| Workflow targets | `ubuntu-24.04`, Node 22, `supabase/setup-cli@v1` (`version: latest`), `postgresql-client` via apt | workflow file (unverified on GitHub) |
| This sandbox | Node v22.23.5, python3; no supabase/psql/docker/deno/postgres; no network | commands executed |

## B. Migration results
| Migration | Applied successfully | Evidence |
|---|---|---|
| 0001 … 0007 | **NOT RUN** | No PostgreSQL available. The runner (`scripts/run-db-tests.sh`) now verifies each file name in the `supabase db reset` output AND the versions in `supabase_migrations.schema_migrations` — that check is untested against a real CLI. |

## C. Test results
| Suite | Executed | Result | Failures |
|---|---|---|---|
| TypeScript (`npm test`) | Yes | **PASS 72/72** | none |
| OpenAPI (`npm run test:contract`) | Yes | **PASS 18/18** | none |
| Workflow/script policy (`npm run test:workflow`, new) | Yes | **PASS 11/11** | none (found 1 real workflow bug, see D) |
| Migrations on PostgreSQL | **No** | NOT RUN | — |
| pgTAP (5 files) | **No** | NOT RUN | — |
| RLS | **No** | NOT RUN | — |
| Storage | **No** | NOT RUN | — |
| Concurrency | **No** | NOT RUN | — |
| `npm run test:db` here | Yes (preflight only) | **BLOCKED** | `MISSING TOOL: supabase` |

The 72 TypeScript tests include control-flow tests of `run-db-tests.sh` with **fake** tools. They prove the runner fails on a missing migration, a pgTAP file that never ran, wrong seed counts, pgTAP failure and concurrency failure. They are **not** database evidence.

## D. Changes made (every discovered problem)
| Problem | Root cause | Files | Fix | Regression test | Result |
|---|---|---|---|---|---|
| DB guard accepted remote databases | `case "$DB_URL" in *127.0.0.1*\|*localhost*)` is a substring test: `postgresql://127.0.0.1:pw@db.<ref>.supabase.co:5432/postgres` passed (proved: with the old guard the real `run-db-tests.sh` ran past the check and started executing) | `scripts/assert-local-db.mjs` (new), `scripts/run-db-tests.sh`, `tests/db/concurrency.sh` | Parse the URL; host must be exactly `127.0.0.1`/`localhost`/`[::1]`; explicit numeric port 1024–65535 (and equal to the local Supabase DB port 54322 in the runner); scheme postgres(ql); reject multi-host, malformed, whitespace, any libpq query parameter other than sslmode/connect_timeout/application_name (`host=`, `hostaddr=`…), and `PGHOST/PGHOSTADDR/PGSERVICE/PGSERVICEFILE` in the environment. Guard runs before any other tool. | `tests/assert-local-db.test.ts` (8): attack URLs the old check accepted, remote/pooler hosts, tricky hosts, malformed URLs, query/env redirection, and both scripts exit 2 before invoking any tool | PASS |
| Runner comment/flow outdated; no verification | said "0001..0006"; never checked migrations, seeds or that all pgTAP files ran | `scripts/run-db-tests.sh` | Phases A–E with preflight (Docker reachable, tool versions logged to `.ci-logs/environment.txt`), PostgreSQL readiness wait, per-file + migration-table check for 0001–0007, seeds loaded twice (idempotency) with count/FK checks against the fixtures, requires all five pgTAP files in the output and no failures, runs concurrency, tees logs | `tests/db-script-flow.test.ts` (7, fake tools) | PASS (flow logic only) |
| Workflow YAML was invalid | job name contained `: ` unquoted (found by the new lint; GitHub would have rejected the file) | `.github/workflows/backend-tests.yml` | rewritten: `permissions: contents: read`, `timeout-minutes` (10/45), pinned `ubuntu-24.04`, Docker verification, explicit `postgresql-client` install, Supabase CLI install + version print, failing `run-db-tests.sh` step (no `continue-on-error`), diagnostics + artifact upload + `supabase stop` with `if: always()`, no secrets, no Cloud references; static and contract jobs preserved, workflow-lint job step added | `tests/workflow_lint.py` (11) incl. mutation check (4 injected violations → 4 failures) | PASS |
| pgTAP might not be enabled | tests assumed the extension | `supabase/tests/database/*.test.sql` | `create extension if not exists pgtap with schema extensions;` in each file | (needs real run) | NOT RUN |
| Local PG version could differ from Cloud | no `[db]` section | `supabase/config.toml` | `[db] major_version = 17` (Cloud is 17.12, read-only inspection) | — | NOT RUN |
| `ci` logs would be committed | — | `.gitignore` | `.ci-logs/` ignored | — | — |
No migration was modified in this task (no SQL failure has been observed yet).

## E. GitHub Actions evidence
None: no workflow run exists. Workflow run URL: **N/A**. Branch/commit: **N/A** (nothing was pushed anywhere).
To obtain the proof (exact steps):
1. Create a (private) GitHub repository for this backend and push the project: `git init && git add -A && git commit -m "backend" && git branch -M main && git remote add origin <url> && git push -u origin main`.
2. `git switch -c ci/db-runtime-verification && git push -u origin ci/db-runtime-verification` (the workflow runs on every push; or Actions → backend-tests → *Run workflow*).
3. Open the run → job `database`; download artifact `database-test-logs` (`environment.txt`, `db-reset.log`, `pgtap.log`, `concurrency.log`, Docker/DB container logs) and send me the job output. I will fix whatever fails and you re-run.
Alternatively locally (Docker + Supabase CLI + psql): `npm run test:db`.
If you give me the `owner/repo` of the project repository I can push a branch to it with the GitHub tools; I still cannot read Actions logs, so you would send me the output.

## F. Remaining risks (unverified, expected first-run corrections)
- Everything marked NOT RUN, including SQL syntax/semantics of 0001–0007 and the pgTAP/concurrency files.
- Assumptions about the Supabase CLI to be checked on first run: migration files named `0001_name.sql` are accepted and recorded with version `0001`; `supabase test db` prints each `*.test.sql` name; required columns of `auth.users`/`storage.objects`; `supabase/setup-cli@v1` with `version: latest` (pin after the first green run).
- Unchanged earlier limits: CV storage objects are not deleted with their row; client-declared `size_bytes`; no rate limit on `force=true`; waitlist promotion unspecified; open decisions A2/A3.
