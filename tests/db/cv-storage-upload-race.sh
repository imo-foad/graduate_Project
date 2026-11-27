#!/usr/bin/env bash
# Real local Storage API upload vs CV tombstone race (issue #18).
# A temporary AFTER INSERT trigger pauses an actual Storage API upload after its RLS
# policy has acquired the shared path advisory lock. The second session then attempts
# metadata deletion. This exercises storage.objects INSERT policy behavior and the
# cleanup worker against real local object bytes, not hand-inserted Storage rows.
set -euo pipefail
cd "$(dirname "$0")/../.."

for tool in node psql curl; do
  command -v "$tool" >/dev/null || { echo "MISSING TOOL: $tool" >&2; exit 3; }
done

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
node scripts/assert-local-db.mjs "$DB_URL" >/dev/null

: "${SUPABASE_URL:?SUPABASE_URL must come from the disposable local Supabase stack}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY must come from the disposable local Supabase stack}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY must come from the disposable local Supabase stack}"

node --input-type=module - "$SUPABASE_URL" <<'NODE'
const url = new URL(process.argv[2]);
if (url.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
    url.port !== "54321") {
  console.error("REFUSING Storage race outside the disposable local Supabase API");
  process.exit(2);
}
NODE

TMP="$(mktemp -d)"
TAG="$(node --input-type=module -e 'import { randomUUID } from "node:crypto"; console.log(randomUUID())')"
EMAIL="issue18-storage-race-$TAG@tests.local"
TEST_PASSWORD="$(node --input-type=module -e 'import { randomBytes } from "node:crypto"; console.log(randomBytes(24).toString("base64url"))')"
OWNER=""
USER_TOKEN=""
DELETE_PATH=""
UPLOAD_PATH=""
DELETE_DOC=""
UPLOAD_DOC=""
BARRIER_PID=""
BARRIER_READ=""
BARRIER_WRITE=""
BARRIER_KEY=""
DELETE_PID=""
UPLOAD_PID=""
FAILS=0

P() {
  psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$1"
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name (expected=$expected actual=$actual)"
    FAILS=$((FAILS + 1))
  fi
}

wait_for_app_lock_wait() {
  local app="$1" count
  for _ in $(seq 1 1000); do
    count="$(P "select count(*) from pg_catalog.pg_stat_activity
                 where application_name = '$app'
                   and state = 'active'
                   and wait_event_type = 'Lock'")"
    [ "$count" -ge 1 ] && return 0
    sleep 0.01
  done
  echo "TIMEOUT waiting for PostgreSQL lock wait: $app" >&2
  return 1
}

wait_for_storage_insert_lock_wait() {
  local count
  for _ in $(seq 1 1000); do
    count="$(P "select count(*) from pg_catalog.pg_stat_activity
                 where state = 'active'
                   and wait_event_type = 'Lock'
                   and query ilike '%storage.objects%'")"
    [ "$count" -ge 1 ] && return 0
    sleep 0.01
  done
  echo "TIMEOUT waiting for actual Storage API INSERT to block on an advisory lock" >&2
  return 1
}

start_barrier() {
  local key="$1" marker="$2" line
  BARRIER_KEY="$key"
  unset ISSUE18_BARRIER_PSQL ISSUE18_BARRIER_PSQL_PID 2>/dev/null || true
  coproc ISSUE18_BARRIER_PSQL { psql "$DB_URL" -X -q -A -t; }
  BARRIER_PID="$ISSUE18_BARRIER_PSQL_PID"
  BARRIER_READ="${ISSUE18_BARRIER_PSQL[0]}"
  BARRIER_WRITE="${ISSUE18_BARRIER_PSQL[1]}"
  printf '%s\n' "select pg_catalog.pg_advisory_lock($key);" "\\echo $marker" >&"$BARRIER_WRITE"
  while IFS= read -r -t 10 line <&"$BARRIER_READ"; do
    [ -z "$line" ] && continue
    [ "$line" = "$marker" ] && return 0
  done
  echo "TIMEOUT acquiring deterministic Storage race barrier" >&2
  return 1
}

release_barrier() {
  local marker="$1" line
  [ -n "$BARRIER_PID" ] || return 0
  printf '%s\n' "select pg_catalog.pg_advisory_unlock($BARRIER_KEY);" "\\echo $marker" "\\q" >&"$BARRIER_WRITE"
  while IFS= read -r -t 10 line <&"$BARRIER_READ"; do
    [ "$line" = "$marker" ] && break
  done
  wait "$BARRIER_PID"
  exec {BARRIER_READ}<&-
  exec {BARRIER_WRITE}>&-
  BARRIER_PID=""
}

upload_in_background() {
  local object_path="$1" prefix="$2"
  (
    local code
    code="$(curl -sS -o "$TMP/$prefix.body" -w '%{http_code}' \
      -X POST "$SUPABASE_URL/storage/v1/object/cv-documents/$object_path" \
      -H "apikey: $SUPABASE_ANON_KEY" \
      -H "Authorization: Bearer $USER_TOKEN" \
      -H "Content-Type: application/pdf" \
      -H "x-upsert: false" \
      --data-binary "@$TMP/cv.pdf" 2>"$TMP/$prefix.curl.err")" || code="000"
    printf '%s\n' "$code" > "$TMP/$prefix.status"
  ) &
  UPLOAD_PID=$!
}

download_status() {
  local object_path="$1" prefix="$2"
  curl -sS -o "$TMP/$prefix.body" -w '%{http_code}' \
    "$SUPABASE_URL/storage/v1/object/cv-documents/$object_path" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $USER_TOKEN" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT
  set +e

  # Release any held barrier before stopping blocked sessions.
  if [ -n "$BARRIER_PID" ]; then
    printf '%s\n' "select pg_catalog.pg_advisory_unlock($BARRIER_KEY);" "\\q" >&"$BARRIER_WRITE" 2>/dev/null
    kill "$BARRIER_PID" >/dev/null 2>&1
    wait "$BARRIER_PID" >/dev/null 2>&1
  fi
  [ -n "$UPLOAD_PID" ] && kill "$UPLOAD_PID" >/dev/null 2>&1
  [ -n "$DELETE_PID" ] && kill "$DELETE_PID" >/dev/null 2>&1
  [ -n "$UPLOAD_PID" ] && wait "$UPLOAD_PID" >/dev/null 2>&1
  [ -n "$DELETE_PID" ] && wait "$DELETE_PID" >/dev/null 2>&1

  # Remove the test-only pause trigger before attempting any Storage cleanup.
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
    "drop trigger if exists zz_issue18_pause_storage_insert on storage.objects;
     drop schema if exists issue18_storage_race cascade;" >/dev/null 2>&1

  if [ -n "$USER_TOKEN" ]; then
    for object_path in "$DELETE_PATH" "$UPLOAD_PATH"; do
      [ -n "$object_path" ] || continue
      curl -sS -o /dev/null -X DELETE \
        "$SUPABASE_URL/storage/v1/object/cv-documents/$object_path" \
        -H "apikey: $SUPABASE_ANON_KEY" \
        -H "Authorization: Bearer $USER_TOKEN" >/dev/null 2>&1
    done
  fi

  if [ -n "$OWNER" ]; then
    curl -sS -o /dev/null -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$OWNER" \
      -H "apikey: $SUPABASE_ANON_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" >/dev/null 2>&1
    psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
      "delete from public.cv_documents where storage_path in ('$DELETE_PATH', '$UPLOAD_PATH');
       delete from private.cv_cleanup_queue where storage_path in ('$DELETE_PATH', '$UPLOAD_PATH');
       delete from auth.users where id = '$OWNER';" >/dev/null 2>&1
  fi

  rm -rf "$TMP"
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  if [ "$FAILS" -ne 0 ]; then
    echo "CV STORAGE UPLOAD RACE FAILED: $FAILS checks" >&2
    exit 1
  fi
}
trap cleanup EXIT

# Provision one disposable user through local Auth so the upload uses a real authenticated JWT.
node --input-type=module - "$TMP/create-user.json" "$EMAIL" "$TEST_PASSWORD" <<'NODE'
import { writeFileSync } from "node:fs";
const [, , output, email, password] = process.argv;
writeFileSync(output, JSON.stringify({ email, password, email_confirm: true }), { mode: 0o600 });
NODE
CREATE_STATUS="$(curl -sS -o "$TMP/create-user.response" -w '%{http_code}' \
  -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@$TMP/create-user.json")"
check "local Auth provisions the disposable race account" "1" "$([ "$CREATE_STATUS" = "200" ] || [ "$CREATE_STATUS" = "201" ] && echo 1 || echo 0)"
OWNER="$(node --input-type=module - "$TMP/create-user.response" <<'NODE'
import { readFileSync } from "node:fs";
const user = JSON.parse(readFileSync(process.argv[2], "utf8"));
process.stdout.write(user.id ?? "");
NODE
)"
[ -n "$OWNER" ] || { echo "PREREQUISITE FAILED: local Auth did not return a user ID" >&2; exit 2; }

node --input-type=module - "$TMP/login.json" "$EMAIL" "$TEST_PASSWORD" <<'NODE'
import { writeFileSync } from "node:fs";
const [, , output, email, password] = process.argv;
writeFileSync(output, JSON.stringify({ email, password }), { mode: 0o600 });
NODE
LOGIN_STATUS="$(curl -sS -o "$TMP/login.response" -w '%{http_code}' \
  -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@$TMP/login.json")"
check "disposable race account receives an authenticated Storage token" "200" "$LOGIN_STATUS"
USER_TOKEN="$(node --input-type=module - "$TMP/login.response" <<'NODE'
import { readFileSync } from "node:fs";
const payload = JSON.parse(readFileSync(process.argv[2], "utf8"));
process.stdout.write(payload.access_token ?? "");
NODE
)"
[ -n "$USER_TOKEN" ] || { echo "PREREQUISITE FAILED: local Auth did not return an access token" >&2; exit 2; }

# Only a synthetic PDF is uploaded. Its bytes remain inside the disposable local Storage stack.
printf '%%PDF-1.4\n%% Issue 18 synthetic local Storage race\n1 0 obj << /Type /Catalog >> endobj\n%%%%EOF\n' > "$TMP/cv.pdf"
chmod 600 "$TMP/cv.pdf"
DELETE_PATH="$OWNER/issue18-delete-first-$TAG.pdf"
UPLOAD_PATH="$OWNER/issue18-upload-first-$TAG.pdf"

P "insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
   values ('$OWNER', '$DELETE_PATH', 'pdf', 128)
   returning id" > "$TMP/delete-doc.id"
DELETE_DOC="$(tr -d '[:space:]' < "$TMP/delete-doc.id")"
P "insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
   values ('$OWNER', '$UPLOAD_PATH', 'pdf', 128)
   returning id" > "$TMP/upload-doc.id"
UPLOAD_DOC="$(tr -d '[:space:]' < "$TMP/upload-doc.id")"
[ -n "$DELETE_DOC" ] && [ -n "$UPLOAD_DOC" ] || {
  echo "PREREQUISITE FAILED: could not create both CV metadata fixtures" >&2
  exit 2
}

# Ordering A: deletion acquires the shared path lock and remains uncommitted.
DELETE_BARRIER=918180000000001101
start_barrier "$DELETE_BARRIER" "DELETE_BARRIER_READY"
PGAPPNAME="issue18-storage-delete-first" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  >"$TMP/delete-first.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-storage-delete-first';
select pg_catalog.set_config('request.jwt.claims',
  jsonb_build_object('sub', '$OWNER', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.delete_cv_document('$DELETE_DOC');
reset role;
select pg_catalog.pg_advisory_lock($DELETE_BARRIER);
commit;
SQL
DELETE_PID=$!
wait_for_app_lock_wait "issue18-storage-delete-first"

upload_in_background "$DELETE_PATH" "delete-first-upload"
wait_for_storage_insert_lock_wait
release_barrier "DELETE_BARRIER_RELEASED"
set +e
wait "$DELETE_PID"; DELETE_STATUS=$?
wait "$UPLOAD_PID"; UPLOAD_WAIT_STATUS=$?
set -e
DELETE_PID=""; UPLOAD_PID=""
UPLOAD_HTTP_STATUS="$(cat "$TMP/delete-first-upload.status" 2>/dev/null || echo 000)"
check "storage upload blocks on the path lock while deletion is uncommitted, then is rejected" \
  "1" "$([ "$DELETE_STATUS" -eq 0 ] && { [ "$UPLOAD_HTTP_STATUS" = "400" ] || [ "$UPLOAD_HTTP_STATUS" = "403" ]; } && \
    [ "$(P "select count(*) from storage.objects where bucket_id = 'cv-documents' and name = '$DELETE_PATH'")" = "0" ] && \
    [ "$(P "select count(*) from private.cv_cleanup_queue where storage_path = '$DELETE_PATH'")" = "1" ] && \
    [ "$(download_status "$DELETE_PATH" "delete-first-download")" != "200" ] && echo 1 || echo 0)"
check "delete-first tombstone is committed with no live CV metadata" "0" \
  "$(P "select count(*) from public.cv_documents d join private.cv_cleanup_queue q on q.storage_path = d.storage_path where q.storage_path = '$DELETE_PATH'")"

# Ordering B: a real Storage API upload wins the path lock; deletion must wait behind it.
UPLOAD_BARRIER=918180000000001102
P "create schema issue18_storage_race;
   create function issue18_storage_race.pause_storage_insert()
   returns trigger language plpgsql security definer set search_path = ''
   as \$pause\$
   begin
     if new.bucket_id = 'cv-documents' and new.name = '$UPLOAD_PATH' then
       perform pg_catalog.pg_advisory_lock($UPLOAD_BARRIER);
     end if;
     return new;
   end
   \$pause\$;
   create trigger zz_issue18_pause_storage_insert
   after insert on storage.objects
   for each row execute function issue18_storage_race.pause_storage_insert();" >/dev/null

start_barrier "$UPLOAD_BARRIER" "UPLOAD_BARRIER_READY"
upload_in_background "$UPLOAD_PATH" "upload-first"
wait_for_storage_insert_lock_wait

PGAPPNAME="issue18-storage-delete-after-upload" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  >"$TMP/delete-after-upload.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-storage-delete-after-upload';
select pg_catalog.set_config('request.jwt.claims',
  jsonb_build_object('sub', '$OWNER', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.delete_cv_document('$UPLOAD_DOC');
reset role;
commit;
SQL
DELETE_PID=$!
wait_for_app_lock_wait "issue18-storage-delete-after-upload"
release_barrier "UPLOAD_BARRIER_RELEASED"
set +e
wait "$UPLOAD_PID"; UPLOAD_WAIT_STATUS=$?
wait "$DELETE_PID"; DELETE_STATUS=$?
set -e
UPLOAD_PID=""; DELETE_PID=""
UPLOAD_HTTP_STATUS="$(cat "$TMP/upload-first.status" 2>/dev/null || echo 000)"
check "upload-first Storage API request completes before deletion commits" "200" "$UPLOAD_HTTP_STATUS"
check "upload-first metadata deletion commits after waiting for the upload lock" "0" "$DELETE_STATUS"
check "upload that wins the lock leaves one object and one tombstone before worker" "1" \
  "$([ "$(P "select count(*) from storage.objects where bucket_id = 'cv-documents' and name = '$UPLOAD_PATH'")" = "1" ] && \
     [ "$(P "select count(*) from private.cv_cleanup_queue where storage_path = '$UPLOAD_PATH' and status = 'PENDING'")" = "1" ] && \
     [ "$(P "select count(*) from public.cv_documents where storage_path = '$UPLOAD_PATH'")" = "0" ] && \
     [ "$(download_status "$UPLOAD_PATH" "upload-first-before-worker")" = "200" ] && echo 1 || echo 0)"

# The worker must remove the actual local Storage object bytes after the tombstone is committed.
WORKER_STATUS="$(curl -sS -o "$TMP/worker.response" -w '%{http_code}' \
  -X POST "$SUPABASE_URL/functions/v1/cleanup-cv-objects" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  --data '{}')"
check "worker accepts the local service-role cleanup request" "200" "$WORKER_STATUS"
check "upload that wins the lock is still removed by the worker after tombstone" "1" \
  "$([ "$(P "select count(*) from storage.objects where bucket_id = 'cv-documents' and name = '$UPLOAD_PATH'")" = "0" ] && \
     [ "$(P "select count(*) from private.cv_cleanup_queue where storage_path = '$UPLOAD_PATH' and status = 'DONE'")" = "1" ] && \
     [ "$(download_status "$UPLOAD_PATH" "upload-first-after-worker")" != "200" ] && echo 1 || echo 0)"

echo "CV STORAGE UPLOAD RACE PASSED"
