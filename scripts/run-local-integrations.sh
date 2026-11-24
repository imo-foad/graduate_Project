#!/usr/bin/env bash
# End-to-end checks against the disposable LOCAL Supabase stack only.
# Requires the caller to have started Supabase and applied migrations + catalogue seeds.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR=".ci-logs"
mkdir -p "$LOG_DIR"
need() { command -v "$1" >/dev/null || { echo "MISSING TOOL: $1" >&2; exit 3; }; }
for t in node supabase psql curl timeout; do need "$t"; done

# Refuse any non-local target before creating Auth users or touching Storage.
node scripts/assert-local-db.mjs "${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}" >/dev/null
LOCAL_ENV="$(mktemp)"
FUNCTION_PID=""
cleanup() {
  if [ -n "$FUNCTION_PID" ]; then kill "$FUNCTION_PID" >/dev/null 2>&1 || true; wait "$FUNCTION_PID" >/dev/null 2>&1 || true; fi
  rm -f "$LOCAL_ENV"
}
trap cleanup EXIT

# Export only the local stack values needed by Auth, Storage and the Function.
supabase status -o env \
  --override-name api.url=SUPABASE_URL \
  --override-name auth.anon_key=SUPABASE_ANON_KEY \
  --override-name auth.service_role_key=SUPABASE_SERVICE_ROLE_KEY > "$LOCAL_ENV"
set -a
. "$LOCAL_ENV"
set +a

[ -n "${SUPABASE_URL:-}" ] || { echo "LOCAL SUPABASE URL missing" >&2; exit 4; }
[ -n "${SUPABASE_ANON_KEY:-}" ] || { echo "LOCAL ANON KEY missing" >&2; exit 4; }
[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ] || { echo "LOCAL SERVICE ROLE KEY missing" >&2; exit 4; }
node --input-type=module - <<'NODE'
const u = new URL(process.env.SUPABASE_URL);
if (!["127.0.0.1", "localhost", "::1"].includes(u.hostname)) {
  console.error("REFUSING non-local Supabase API URL");
  process.exit(2);
}
NODE

# Disposable password: never write it to the repository, CI logs or artifacts.
export DEMO_PASSWORD="$(node --input-type=module -e 'import { randomBytes } from "node:crypto"; console.log(randomBytes(24).toString("base64url"))')"
echo "Provisioning synthetic Auth demo users (password omitted from logs)"
node scripts/provision-demo-users.mjs | tee "$LOG_DIR/demo-provision-first.log"
# The second pass verifies that provisioning is idempotent for already-created users.
node scripts/provision-demo-users.mjs | tee "$LOG_DIR/demo-provision-second.log"

npm run build:seed > "$LOG_DIR/integration-build-seed.log"
DEMO_SEED="supabase/seed/03_demo_profiles.sql"
[ -s "$DEMO_SEED" ] || { echo "DEMO PROFILE SEED MISSING" >&2; exit 1; }

# Run demo-profile/history seed twice and compare stable row counts.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f "$DEMO_SEED"
EMAILS="'graduate.demo@alumni.test','graduate.android@alumni.test','graduate.data@alumni.test','graduate.cyber@alumni.test'"
PROFILE_COUNT="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.profiles where email in ($EMAILS)")"
GRADUATE_COUNT="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.graduate_profiles gp join public.profiles p on p.id=gp.profile_id where p.email in ($EMAILS)")"
SKILL_COUNT="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.graduate_skills gs join public.profiles p on p.id=gs.graduate_id where p.email in ($EMAILS) and gs.source='SEED'")"
SAMPLE_APP_COUNT_1="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.applications a join public.profiles p on p.id=a.graduate_id where p.email in ($EMAILS) and a.status_source='SEED_SAMPLE'")"
SAMPLE_HISTORY_COUNT_1="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.application_status_history h join public.applications a on a.id=h.application_id join public.profiles p on p.id=a.graduate_id where p.email in ($EMAILS) and h.source_type='SEED_SAMPLE'")"
[ "$PROFILE_COUNT" = "4" ] || { echo "Expected 4 profiles, got $PROFILE_COUNT" >&2; exit 1; }
[ "$GRADUATE_COUNT" = "4" ] || { echo "Expected 4 graduate profiles, got $GRADUATE_COUNT" >&2; exit 1; }
[ "$SKILL_COUNT" -gt 0 ] || { echo "Demo skill seed produced no rows" >&2; exit 1; }
[ "$SAMPLE_APP_COUNT_1" -gt 0 ] || { echo "Demo sample applications are missing" >&2; exit 1; }
psql "$DB_URL" -X -v ON_ERROR_STOP=1 --single-transaction -q -f "$DEMO_SEED"
SAMPLE_APP_COUNT_2="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.applications a join public.profiles p on p.id=a.graduate_id where p.email in ($EMAILS) and a.status_source='SEED_SAMPLE'")"
SAMPLE_HISTORY_COUNT_2="$(psql "$DB_URL" -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.application_status_history h join public.applications a on a.id=h.application_id join public.profiles p on p.id=a.graduate_id where p.email in ($EMAILS) and h.source_type='SEED_SAMPLE'")"
[ "$SAMPLE_APP_COUNT_1" = "$SAMPLE_APP_COUNT_2" ] || { echo "Demo application seed is not idempotent: $SAMPLE_APP_COUNT_1 -> $SAMPLE_APP_COUNT_2" >&2; exit 1; }
[ "$SAMPLE_HISTORY_COUNT_1" = "$SAMPLE_HISTORY_COUNT_2" ] || { echo "Demo history seed is not idempotent: $SAMPLE_HISTORY_COUNT_1 -> $SAMPLE_HISTORY_COUNT_2" >&2; exit 1; }
echo "PASS Auth provisioning + trigger-created profile rows: profiles=$PROFILE_COUNT, graduates=$GRADUATE_COUNT"
echo "PASS demo profile seed idempotency: skills=$SKILL_COUNT, sample applications=$SAMPLE_APP_COUNT_2, sample history=$SAMPLE_HISTORY_COUNT_2"

# Serve the actual Edge Function through the local Supabase gateway with JWT verification ON.
# The function additionally calls auth.getUser(), so both gateway and handler auth paths are exercised.
supabase functions serve --env-file "$LOCAL_ENV" > "$LOG_DIR/functions-serve.log" 2>&1 &
FUNCTION_PID=$!
READY=0
CODE="000"
for _ in $(seq 1 60); do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "apikey: $SUPABASE_ANON_KEY" "$SUPABASE_URL/functions/v1/recommend" 2>/dev/null || true)"
  # The handler rejects non-POST methods before reading the JWT, so a loaded function returns HTTP 405.
  # A 404/503 from the gateway is not proof that the Edge Function has finished loading.
  if [ "$CODE" = "405" ]; then READY=1; break; fi
  if ! kill -0 "$FUNCTION_PID" >/dev/null 2>&1; then echo "Edge Function serve process exited early (last HTTP $CODE)" >&2; tail -100 "$LOG_DIR/recommend-function-serve.log" >&2; exit 1; fi
  sleep 1
done
[ "$READY" = "1" ] || { echo "Edge Function gateway did not become ready: expected HTTP 405 for GET, got $CODE" >&2; tail -80 "$LOG_DIR/recommend-function-serve.log" >&2; exit 1; }

timeout 300s node tests/integration/local-supabase.integration.mjs | tee "$LOG_DIR/http-integration.log"
timeout 300s node tests/integration/cv-parse.integration.mjs | tee "$LOG_DIR/cv-parse-integration.log"

# Ten independent graduate accounts: unique CVs, profile tracks, review and full app journeys.
timeout 900s node tests/integration/career-cohort.integration.mjs round1 | tee "$LOG_DIR/career-cohort-round1.log"
timeout 900s node tests/integration/career-cohort.integration.mjs round2 | tee "$LOG_DIR/career-cohort-round2.log"
