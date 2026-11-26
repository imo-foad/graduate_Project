#!/usr/bin/env bash
# Real database proof: clean local DB -> every discovered versioned migration -> seeds -> pgTAP (18 files) -> concurrency. LOCAL ONLY.
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
[ "${#MIGRATIONS[@]}" -gt 0 ] || fail "no versioned SQL migration files were discovered"
PREVIOUS_VERSION=""
for f in "${MIGRATIONS[@]}"; do
  name="$(basename "$f")"
  [[ "$name" =~ ^([0-9]{4})_[A-Za-z0-9][A-Za-z0-9_.-]*[.]sql$ ]] || fail "migration filename is not four-digit versioned: $name"
  version="${BASH_REMATCH[1]}"
  if [[ -n "$PREVIOUS_VERSION" ]] && [[ ! "$version" > "$PREVIOUS_VERSION" ]]; then
    fail "migration versions must be unique and increasing: $name follows version $PREVIOUS_VERSION"
  fi
  PREVIOUS_VERSION="$version"
  grep -q "$(basename "$f")" "$LOG_DIR/db-reset.log" || fail "db reset output does not show $name as applied"
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

# ---- D. pgTAP: all eighteen files must run and pass
echo "=== D. supabase test db"
EXPECTED_TESTS=(01_register_for_event 02_rpc_rules 03_rls_security 04_storage_cv_ownership 05_recommendation_cache 06_company_workflow 07_admin_company_controls 08_cv_parse_lifecycle 09_cv_intelligence 10_cancelled_scope_guard 12_social_feed 13_social_moderation_rate_limits 14_secure_graduate_onboarding 15_three_type_scope 16_cv_cleanup_queue 17_recommendation_availability 18_identity_and_organizations 19_product_lifecycle)
for t in "${EXPECTED_TESTS[@]}"; do [ -f "supabase/tests/database/$t.test.sql" ] || fail "missing test file $t"; done
# Run Test 15 by itself first so its auth/catalogue TAP plan is independently observable.
echo "=== D1. focused Test 15"
supabase test db supabase/tests/database/15_three_type_scope.test.sql 2>&1 | tee "$LOG_DIR/pgtap-15-focused.log"
if grep -Eq "^(not ok|Result: FAIL)|Failed [0-9]+" "$LOG_DIR/pgtap-15-focused.log"; then fail "focused Test 15 reported failures"; fi
grep -Fq "supabase/tests/database/15_three_type_scope.test.sql" "$LOG_DIR/pgtap-15-focused.log" || fail "focused pgTAP output does not show Test 15 execution"
grep -Eq "^Files=1, Tests=[1-9][0-9]*," "$LOG_DIR/pgtap-15-focused.log" || fail "focused Test 15 did not execute a non-empty TAP plan"
grep -Fxq "Result: PASS" "$LOG_DIR/pgtap-15-focused.log" || fail "focused Test 15 TAP plan did not pass"
echo "=== D2. full pgTAP suite"
supabase test db 2>&1 | tee "$LOG_DIR/pgtap.log"
for t in "${EXPECTED_TESTS[@]}"; do grep -q "$t.test.sql" "$LOG_DIR/pgtap.log" || fail "pgTAP output does not show $t.test.sql"; done
if grep -Eq "^(not ok|Result: FAIL)|Failed [0-9]+" "$LOG_DIR/pgtap.log"; then fail "pgTAP reported failures"; fi
grep -Eq "^Files=18, Tests=[1-9][0-9]*," "$LOG_DIR/pgtap.log" || fail "full pgTAP suite did not execute all 18 files with a non-empty TAP plan"
grep -Fxq "Result: PASS" "$LOG_DIR/pgtap.log" || fail "full pgTAP TAP plan did not pass"

# ---- E. real concurrent sessions
echo "=== E. concurrency"
bash tests/db/concurrency.sh 2>&1 | tee "$LOG_DIR/concurrency.log"

# ---- F. local HTTP integration: Auth provisioning + demo seed + Storage API + Edge Function
echo "=== F. local Supabase HTTP integration"
bash scripts/run-local-integrations.sh 2>&1 | tee "$LOG_DIR/local-integrations.log"

echo "DB TESTS PASSED"
