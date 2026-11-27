#!/usr/bin/env bash
# Independent, disposable local Supabase proof for the 40-account university seed.
# It deliberately does not depend on QA-owned pgTAP tests completing.
#
# Exit-status contract: the EXIT trap preserves the original failure status. Cleanup is
# best-effort and can never turn a failed setup/migration/seed into a successful job.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR=".ci-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/university-seed-smoke.log"
: > "$LOG_FILE"

# Redact ephemeral Supabase CLI keys/JWTs and credential-like assignments before any
# startup output is copied to the public Actions log or downloadable artifact.
redact_ci_file() {
  sed -E -i \
    -e 's/sb_secret_[A-Za-z0-9_-]{20,}/[REDACTED_LOCAL_SUPABASE_SECRET]/g' \
    -e 's/sb_publishable_[A-Za-z0-9_-]{20,}/[REDACTED_LOCAL_SUPABASE_PUBLISHABLE]/g' \
    -e 's/^[[:space:]│]*(Secret Key|Publishable Key|Anon Key|Service Role Key|JWT Secret|DB URL)[[:space:]│]*.*/[REDACTED_LOCAL_SUPABASE_VALUE]/' \
    -e 's/eyJ[A-Za-z0-9_-]{20,}[.][A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}/[REDACTED_LOCAL_JWT]/g' \
    -e 's/(SERVICE_ROLE_KEY|ANON_KEY|JWT_SECRET|DB_PASSWORD|S3_ACCESS_KEY_ID|S3_SECRET_ACCESS_KEY)[[:space:]]*=[[:space:]]*[^[:space:]]+/[REDACTED_CREDENTIAL_ASSIGNMENT]/Ig' \
    -e 's/Authorization: Bearer [A-Za-z0-9._-]{20,}/Authorization: Bearer [REDACTED]/Ig' \
    -e 's/apikey: [A-Za-z0-9._-]{20,}/apikey: [REDACTED]/Ig' "$1"
}

# Mirror every later line into the downloadable artifact log. This happens before the first
# tool check so startup and migration failures are always diagnosable.
# Keep original streams so the process-substitution tee can be cleanly closed and joined in cleanup.
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID="$!"
echo "=== synthetic university smoke started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
export DB_URL

# Validate the DB target before starting tools or making any network/database call.
node scripts/assert-local-db.mjs "$DB_URL"
[ "$(node -e 'console.log(new URL(process.argv[1]).port)' "$DB_URL")" = "54322" ] || {
  echo "REFUSING non-local Supabase DB port" >&2
  exit 2
}

need() { command -v "$1" >/dev/null || { echo "MISSING TOOL: $1" >&2; exit 3; }; }
for tool in node npm supabase docker psql curl timeout; do need "$tool"; done
docker info >/dev/null

LOCAL_ENV="$(mktemp)"
FUNCTION_PID=""
cleanup() {
  # Capture the real status first: everything below is best-effort and must not mask it.
  local status=$?
  trap - EXIT
  set +e
  echo "=== cleanup started (original exit status: $status)"
  if [ -n "$FUNCTION_PID" ]; then
    kill "$FUNCTION_PID" >/dev/null 2>&1 || true
    wait "$FUNCTION_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$LOCAL_ENV"
  timeout 120s supabase stop --no-backup >>"$LOG_DIR/supabase-stop.log" 2>&1 || true
  for log_file in "$LOG_DIR"/*; do
    [ -f "$log_file" ] && redact_ci_file "$log_file"
  done
  # Close the process-substitution pipe and wait for tee to flush all prior diagnostics.
  exec 1>&3 2>&4
  wait "$TEE_PID" || true
  local marker
  if [ "$status" -eq 0 ]; then
    marker="SMOKE RESULT: PASS"
  else
    marker="SMOKE RESULT: FAIL (exit status $status) — see $LOG_FILE"
  fi
  # Public annotation for the same reason as the DB runner: logs/summaries need admin credentials.
  if [ "$status" -ne 0 ]; then
    local announce
    announce="$(tail -n 4 "$LOG_FILE" | tr '\n' ' ' | cut -c1-700)"
    printf '::error title=UNIVERSITY_SEED_SMOKE_FAILED::exit %s | %s\n' "$status" "$announce"
  fi
  # Job logs need repository-admin credentials to download; a short redacted tail in the public
  # job summary keeps a failed stage diagnosable without exposing keys, JWTs or CV content.
  if [ "$status" -ne 0 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Synthetic university seed job failed (exit $status)"
      for tail_file in "$LOG_DIR/university-seed-supabase-start.log" "$LOG_DIR/university-seed-db-reset.log" "$LOG_FILE"; do
        [ -s "$tail_file" ] || continue
        echo "### $(basename "$tail_file")"
        echo '```'
        tail -n 30 "$tail_file"
        echo '```'
      done
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  # Append the terminal result only after tee exits, so artifact verification never races it.
  printf '%s\n' "$marker" >> "$LOG_FILE"
  printf '%s\n' "$marker"
  exec 3>&- 4>&-
  exit "$status"
}
trap cleanup EXIT

echo "=== starting disposable local Supabase stack"
START_LOG="$(mktemp)"
START_STATUS=0
supabase start >"$START_LOG" 2>&1 || START_STATUS=$?
redact_ci_file "$START_LOG"
tee "$LOG_DIR/university-seed-supabase-start.log" < "$START_LOG"
rm -f "$START_LOG"
[ "$START_STATUS" -eq 0 ] || exit "$START_STATUS"

echo "=== applying a clean database reset (all migrations)"
supabase db reset 2>&1 | tee "$LOG_DIR/university-seed-db-reset.log"

supabase status -o env \
  --override-name api.url=SUPABASE_URL \
  --override-name auth.anon_key=SUPABASE_ANON_KEY \
  --override-name auth.service_role_key=SUPABASE_SERVICE_ROLE_KEY > "$LOCAL_ENV"
set -a
. "$LOCAL_ENV"
set +a

[ -n "${SUPABASE_URL:-}" ] || { echo "LOCAL SUPABASE_URL is missing" >&2; exit 4; }
[ -n "${SUPABASE_ANON_KEY:-}" ] || { echo "LOCAL SUPABASE_ANON_KEY is missing" >&2; exit 4; }
[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] || { echo "LOCAL SUPABASE_SERVICE_ROLE_KEY is missing" >&2; exit 4; }
node --input-type=module - <<'NODE'
const api = new URL(process.env.SUPABASE_URL);
if (api.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(api.hostname) || api.port !== "54321") {
  console.error("REFUSING non-local Supabase API URL");
  process.exit(2);
}
const db = new URL(process.env.DB_URL);
if (!["127.0.0.1", "localhost", "::1"].includes(db.hostname) || db.port !== "54322") {
  console.error("REFUSING non-local Supabase DB URL");
  process.exit(2);
}
NODE

# A fresh disposable password is supplied through the environment only and never printed.
export DEMO_PASSWORD="$(node --input-type=module -e 'import { randomBytes } from "node:crypto"; console.log(randomBytes(24).toString("base64url"))')"
npm run build:seed 2>&1 | tee "$LOG_DIR/university-seed-build.log"

# The legacy catalogue fixtures are retained and applied before the four graduate demo profiles.
for seed_file in supabase/seed/01_skills.sql supabase/seed/02_catalogue.sql; do
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f "$seed_file"
done

echo "=== provisioning four existing graduate demo accounts"
node scripts/provision-demo-users.mjs 2>&1 | tee "$LOG_DIR/graduate-demo-provision.log"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f supabase/seed/03_demo_profiles.sql

# This provisions 40 phone-only Auth users, applies the typed rows/admin grants twice,
# and asserts 20/10/10, 20 unique GPA values, seven tracks, zero graduate leakage, and four existing grads.
echo "=== provisioning synthetic university accounts and applying seed twice"
node scripts/seed-university-demo.mjs 2>&1 | tee "$LOG_DIR/university-seed-apply.log"

# Independent post-seed verification (independent of the JavaScript assertions above).
echo "=== post-seed database verification"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' 2>&1 | tee "$LOG_DIR/university-seed-verification.log"
select 'students' as metric, count(*)::text as value from public.student_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'faculty', count(*)::text from public.faculty_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'admins', count(*)::text from private.platform_admins a join public.profiles p on p.id = a.user_id
  where a.is_active and p.phone between '+12125550130' and '+12125550139'
union all select 'distinct_gpa', count(distinct gpa)::text from public.student_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'gpa_min', min(gpa)::text from public.student_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'gpa_max', max(gpa)::text from public.student_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'tracks', count(distinct academic_track)::text from public.student_academic_records where record_source = 'SYNTHETIC_SEED'
union all select 'synthetic_phones', count(distinct phone)::text from public.profiles
  where phone between '+12125550100' and '+12125550139'
union all select 'graduate_demos', count(*)::text from public.profiles p join public.graduate_profiles gp on gp.profile_id = p.id
  where p.email in ('graduate.demo@alumni.test','graduate.android@alumni.test','graduate.data@alumni.test','graduate.cyber@alumni.test')
union all select 'graduate_leakage', count(*)::text from public.profiles p join public.graduate_profiles gp on gp.profile_id = p.id
  where p.phone between '+12125550100' and '+12125550139';
SQL

# Provisioning is not considered healthy until existing phone-only accounts can authenticate and
# the role/RLS boundary checks pass through the real local HTTP API.
echo "=== verifying phone/password Auth, academic-record RLS and platform-admin boundaries"
node tests/integration/university-dataset.integration.mjs 2>&1 | tee "$LOG_DIR/university-dataset-integration.log"

# Also run the synthetic PDF/DOCX CV field-accuracy harness against the actual local Edge Function.
supabase functions serve --env-file "$LOCAL_ENV" > "$LOG_DIR/university-seed-functions-serve.log" 2>&1 &
FUNCTION_PID=$!
READY=0
READY_STREAK=0
CODE="000"
for _ in $(seq 1 90); do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "apikey: $SUPABASE_ANON_KEY" "$SUPABASE_URL/functions/v1/recommend" 2>/dev/null || true)"
  if [ "$CODE" = "405" ]; then
    READY_STREAK=$((READY_STREAK + 1))
    if [ "$READY_STREAK" -ge 2 ]; then READY=1; break; fi
  else
    READY_STREAK=0
  fi
  if ! kill -0 "$FUNCTION_PID" >/dev/null 2>&1; then
    echo "Local Edge Function process exited early" >&2
    tail -100 "$LOG_DIR/university-seed-functions-serve.log" >&2
    exit 1
  fi
  sleep 1
done
[ "$READY" = "1" ] || {
  echo "Local Edge Function gateway not ready: expected two HTTP 405 GET responses, received $CODE" >&2
  tail -100 "$LOG_DIR/university-seed-functions-serve.log" >&2
  exit 1
}
node scripts/evaluate-cv-parser-local.mjs 2>&1 | tee "$LOG_DIR/cv-parser-evaluation.log"

echo "PASS: synthetic university seed applied twice to disposable local Supabase"
echo "PASS: Auth first and second pass counts and dataset invariants verified (see university-seed-apply.log)"
echo "PASS: post-seed SQL counts verified (see university-seed-verification.log)"
echo "UNIVERSITY SEED + CV EVALUATION PASSED: local Auth, identities, academic records, admin grants, idempotency and parser metrics"
