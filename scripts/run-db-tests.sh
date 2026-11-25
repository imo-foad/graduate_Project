#!/usr/bin/env bash
# Real database proof: clean local DB -> migrations 0001..0021 -> seeds -> pgTAP (15 files) -> concurrency. LOCAL ONLY.
# Needs: Docker, Supabase CLI, psql, Node. `supabase db reset` DESTROYS the local database: DB_URL is validated first.
# Never use a Cloud URL, never `supabase link`. Every failed command fails this script (no silent skips).
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- 0. guard: parsed host must be exactly 127.0.0.1 / localhost / ::1, port numeric (runs BEFORE any other tool)
export DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
command -v node >/dev/null || { echo "REFUSING: node is required to validate DB_URL" >&2; exit 2; }
node scripts/assert-local-db.mjs "$DB_URL" || exit 2
EXPECTED_PORT="${SUPABASE_DB_PORT:-54322}"   # [db] port of the local Supabase stack
ACTUAL_PORT="$(node -e 'console.log(new URL(process.argv[1]).port)' "$DB_URL")"
[ "$ACTUAL_PORT" = "$EXPECTED_PORT" ] || { echo "REFUSING: DB_URL port $ACTUAL_PORT != local Supabase DB port $EXPECTED_PORT" >&2; exit 2; }

LOG_DIR=".ci-logs"; mkdir -p "$LOG_DIR"
fail() { echo "FAILED: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "MISSING TOOL: $1" >&2; exit 3; }; }
q() { psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "$1"; }

# ---- environment evidence
for t in supabase psql docker npm; do need "$t"; done
echo "=== environment"
{ uname -sr; sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || true
  docker --version; docker info --format 'docker server {{.ServerVersion}}' 2>/dev/null || true
  echo "node $(node -v)"; echo "supabase CLI $(supabase --version)"; psql --version; } | tee "$LOG_DIR/environment.txt"
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

# ---- A. start local stack and wait for PostgreSQL
echo "=== A. supabase start"
supabase start 2>&1 | tee "$LOG_DIR/supabase-start.log"
ready=0; for _ in $(seq 1 30); do q "select 1" >/dev/null 2>&1 && { ready=1; break; }; sleep 2; done
[ "$ready" = 1 ] || fail "PostgreSQL did not become ready on $ACTUAL_PORT"
echo "PostgreSQL server_version: $(q 'show server_version')" | tee -a "$LOG_DIR/environment.txt"

# ---- B. clean reset applies EVERY migration (checked in the CLI output AND in the migration table)
echo "=== B. supabase db reset"
supabase db reset 2>&1 | tee "$LOG_DIR/db-reset.log"
shopt -s nullglob; MIGRATIONS=(supabase/migrations/*.sql); shopt -u nullglob
[ "${#MIGRATIONS[@]}" -ge 20 ] || fail "expected at least 20 migration files, found ${#MIGRATIONS[@]}"
for f in "${MIGRATIONS[@]}"; do
  grep -q "$(basename "$f")" "$LOG_DIR/db-reset.log" || fail "db reset output does not show $(basename "$f") as applied"
done
WANT="$(for f in "${MIGRATIONS[@]}"; do basename "$f" | sed -E 's/^([0-9]+)_.*/\1/'; done | sort | paste -sd, -)"
GOT="$(q "select coalesce(string_agg(version, ',' order by version), '') from supabase_migrations.schema_migrations")"
[ "$WANT" = "$GOT" ] || fail "migration table has [$GOT], expected [$WANT]"
echo "migrations applied: $GOT"

# ---- C. seeds (loaded twice: must be idempotent) + integrity checks
echo "=== C. seeds"
npm run build:seed
for pass in 1 2; do
  for f in supabase/seed/01_skills.sql supabase/seed/02_catalogue.sql; do
    psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f "$f" || fail "seed $f failed (pass $pass)"
  done
done
WANT_SKILLS="$(node -e 'console.log(JSON.parse(require("fs").readFileSync("fixtures/skills.json","utf8")).length)')"
WANT_OPPS="$(node -e 'console.log(JSON.parse(require("fs").readFileSync("fixtures/opportunities.json","utf8")).length)')"
[ "$(q 'select count(*) from public.skills')" = "$WANT_SKILLS" ] || fail "skills count != $WANT_SKILLS"
[ "$(q 'select count(*) from public.opportunities')" = "$WANT_OPPS" ] || fail "opportunities count != $WANT_OPPS"
[ "$(q 'select count(*) from public.opportunity_skills os left join public.skills s on s.id = os.skill_id where s.id is null')" = "0" ] || fail "opportunity_skills reference unknown skills"
echo "seed OK: $WANT_SKILLS skills, $WANT_OPPS opportunities (idempotent on second load)"

# ---- D. pgTAP: all sixteen files must run and pass
echo "=== D. supabase test db"
EXPECTED_TESTS=(01_register_for_event 02_rpc_rules 03_rls_security 04_storage_cv_ownership 05_recommendation_cache 06_company_workflow 07_admin_company_controls 08_cv_parse_lifecycle 09_cv_intelligence 10_scholarship_application 11_competition_application 12_social_feed 14_secure_graduate_onboarding 15_internal_scholarship_management 16_scholarship_delivery_review 17_competition_delivery_review)
for t in "${EXPECTED_TESTS[@]}"; do [ -f "supabase/tests/database/$t.test.sql" ] || fail "missing test file $t"; done
supabase test db 2>&1 | tee "$LOG_DIR/pgtap.log"
for t in "${EXPECTED_TESTS[@]}"; do grep -q "$t.test.sql" "$LOG_DIR/pgtap.log" || fail "pgTAP output does not show $t.test.sql"; done
if grep -Eq '^(not ok|Result: FAIL)|Failed [0-9]+' "$LOG_DIR/pgtap.log"; then fail "pgTAP reported failures"; fi

# ---- E. real concurrent sessions
echo "=== E. concurrency"
bash tests/db/concurrency.sh 2>&1 | tee "$LOG_DIR/concurrency.log"

# ---- F. local HTTP integration: Auth provisioning + demo seed + Storage API + Edge Function
echo "=== F. local Supabase HTTP integration"
bash scripts/run-local-integrations.sh 2>&1 | tee "$LOG_DIR/local-integrations.log"

echo "DB TESTS PASSED"
