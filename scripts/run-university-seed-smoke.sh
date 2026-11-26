#!/usr/bin/env bash
# Independent, disposable local Supabase proof for the 40-account university seed.
# It deliberately does not depend on QA-owned pgTAP tests completing.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR=".ci-logs"
mkdir -p "$LOG_DIR"
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
  if [ -n "$FUNCTION_PID" ]; then kill "$FUNCTION_PID" >/dev/null 2>&1 || true; wait "$FUNCTION_PID" >/dev/null 2>&1 || true; fi
  rm -f "$LOCAL_ENV"
  timeout 120s supabase stop --no-backup >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting disposable local Supabase stack"
supabase start
supabase db reset

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
npm run build:seed > "$LOG_DIR/university-seed-build.log"

# The legacy catalogue fixtures are retained and applied before the four graduate demo profiles.
for seed_file in supabase/seed/01_skills.sql supabase/seed/02_catalogue.sql; do
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f "$seed_file"
done

node scripts/provision-demo-users.mjs > "$LOG_DIR/graduate-demo-provision.log"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f supabase/seed/03_demo_profiles.sql

# This provisions 40 phone-only Auth users, applies the typed rows/admin grants twice,
# and asserts 20/10/10, 20 unique GPA values, seven tracks, zero graduate leakage, and four existing grads.
node scripts/seed-university-demo.mjs | tee "$LOG_DIR/university-seed-apply.log"

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
node scripts/evaluate-cv-parser-local.mjs | tee "$LOG_DIR/cv-parser-evaluation.log"

echo "UNIVERSITY SEED + CV EVALUATION PASSED: local Auth, identities, academic records, admin grants, idempotency and parser metrics"
