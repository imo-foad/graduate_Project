#!/usr/bin/env bash
# Deterministic two-session proof for the Issue #18 CV Storage-path advisory-lock protocol.
# LOCAL ONLY. No sleeps create the race: sessions stop at advisory-lock barriers; the harness
# releases each barrier only after observing the expected blocked session in pg_stat_activity.
set -euo pipefail
cd "$(dirname "$0")/../.."

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
command -v node >/dev/null || { echo "MISSING TOOL: node" >&2; exit 3; }
command -v psql >/dev/null || { echo "MISSING TOOL: psql" >&2; exit 3; }
node scripts/assert-local-db.mjs "$DB_URL" >/dev/null

TMP="$(mktemp -d)"
OWNER="$(node --input-type=module -e 'import { randomUUID } from "node:crypto"; console.log(randomUUID())')"
TAG="$(node --input-type=module -e 'import { randomUUID } from "node:crypto"; console.log(randomUUID())')"
DELETE_PATH="$OWNER/issue18-delete-first-$TAG.pdf"
REVERSE_PATH="$OWNER/issue18-insert-first-$TAG.pdf"
DELETE_DOC=""
REVERSE_DOC=""
BARRIER_PID=""
BARRIER_READ=""
BARRIER_WRITE=""
BARRIER_KEY=""
A_PID=""
B_PID=""
FAILS=0

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [ -n "$BARRIER_PID" ] && kill -0 "$BARRIER_PID" >/dev/null 2>&1; then
    printf '%s\n' "\\q" >&"$BARRIER_WRITE" 2>/dev/null
    kill "$BARRIER_PID" >/dev/null 2>&1
    wait "$BARRIER_PID" >/dev/null 2>&1
  fi
  [ -n "$A_PID" ] && kill "$A_PID" >/dev/null 2>&1
  [ -n "$B_PID" ] && kill "$B_PID" >/dev/null 2>&1
  [ -n "$A_PID" ] && wait "$A_PID" >/dev/null 2>&1
  [ -n "$B_PID" ] && wait "$B_PID" >/dev/null 2>&1
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
    "drop schema if exists issue18_concurrency cascade;
     delete from auth.users where id = '$OWNER';
     delete from private.cv_cleanup_queue where storage_path in ('$DELETE_PATH', '$REVERSE_PATH');" >/dev/null 2>&1
  rm -rf "$TMP"
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  if [ "$FAILS" -ne 0 ]; then
    echo "CV CLEANUP CONCURRENCY FAILED: $FAILS checks" >&2
    exit 1
  fi
  }
trap cleanup EXIT

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

wait_for_lock_wait() {
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

start_barrier() {
  local key="$1" marker="$2" line
  BARRIER_KEY="$key"
  unset CV_BARRIER_PSQL CV_BARRIER_PSQL_PID 2>/dev/null || true
  coproc CV_BARRIER_PSQL { psql "$DB_URL" -X -q -A -t; }
  BARRIER_PID="$CV_BARRIER_PSQL_PID"
  BARRIER_READ="${CV_BARRIER_PSQL[0]}"
  BARRIER_WRITE="${CV_BARRIER_PSQL[1]}"
  printf '%s\n' "select pg_catalog.pg_advisory_lock($key);" "\\echo $marker" >&"$BARRIER_WRITE"
  while IFS= read -r -t 10 line <&"$BARRIER_READ"; do
    [ -z "$line" ] && continue
    [ "$line" = "$marker" ] && return 0
  done
  echo "TIMEOUT acquiring deterministic test barrier" >&2
  return 1
}
release_barrier() {
  local marker="$1" line
  printf '%s\n' "select pg_catalog.pg_advisory_unlock($BARRIER_KEY);" "\\echo $marker" "\\q" >&"$BARRIER_WRITE"
  while IFS= read -r -t 10 line <&"$BARRIER_READ"; do
    [ "$line" = "$marker" ] && break
  done
  wait "$BARRIER_PID"
  exec {BARRIER_READ}<&-
  exec {BARRIER_WRITE}>&-
  BARRIER_PID=""
}
# Create one disposable Auth user. The database trigger creates its profile/graduate profile.
P "insert into auth.users (id, aud, role, email, raw_user_meta_data)
   values ('$OWNER', 'authenticated', 'authenticated',
           'issue18-race-$TAG@tests.local', jsonb_build_object('full_name','Issue 18 race fixture'))" >/dev/null

DELETE_DOC="$(P "insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
                  values ('$OWNER', '$DELETE_PATH', 'pdf', 128)
                  returning id")"
REVERSE_DOC="$(P "insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
                   values ('$OWNER', '$REVERSE_PATH', 'pdf', 128)
                   returning id")"
[ -n "$DELETE_DOC" ] && [ -n "$REVERSE_DOC" ] || {
  echo "PREREQUISITE FAILED: could not create two CV metadata fixtures" >&2
  exit 2
}
check "both fresh Storage paths start with one live metadata row" "2" \
  "$(P "select count(*) from public.cv_documents where storage_path in ('$DELETE_PATH', '$REVERSE_PATH')")"

# Ordering 1: deletion has queued the path and waits before COMMIT; the later
# registration must block on the path lock and fail after deletion commits.
DELETE_BARRIER=918180000000001001
start_barrier "$DELETE_BARRIER" "DELETE_BARRIER_READY"
PGAPPNAME="issue18-delete-first" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$TMP/delete-first.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-delete-first';
select pg_catalog.set_config('request.jwt.claims',
  jsonb_build_object('sub', '$OWNER', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.delete_cv_document('$DELETE_DOC');
reset role;
select pg_catalog.pg_advisory_lock($DELETE_BARRIER);
commit;
SQL
A_PID=$!
wait_for_lock_wait "issue18-delete-first"

PGAPPNAME="issue18-insert-after-delete" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$TMP/insert-after-delete.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-insert-after-delete';
set local role service_role;
insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
values ('$OWNER', '$DELETE_PATH', 'pdf', 128);
commit;
SQL
B_PID=$!
wait_for_lock_wait "issue18-insert-after-delete"
release_barrier "DELETE_BARRIER_RELEASED"

set +e
wait "$A_PID"; A_STATUS=$?
wait "$B_PID"; B_STATUS=$?
set -e
A_PID=""; B_PID=""
check "delete-first transaction commits" "0" "$A_STATUS"
check "registration after deletion is rejected" "3" "$B_STATUS"
grep -Fq "CV_STORAGE_PATH_RETIRED" "$TMP/insert-after-delete.log" \
  && check "delete-first rejection carries CV_STORAGE_PATH_RETIRED" "1" "1" \
  || check "delete-first rejection carries CV_STORAGE_PATH_RETIRED" "1" "0"
check "delete-first path has one queue tombstone" "1" \
  "$(P "select count(*) from private.cv_cleanup_queue where storage_path = '$DELETE_PATH'")"
check "delete-first path has no live metadata" "0" \
  "$(P "select count(*) from public.cv_documents where storage_path = '$DELETE_PATH'")"

# Ordering 2: insert obtains the path lock first while the old metadata row is
# still present. A local test-only trigger pauses after the real guard; deletion
# must wait, then proceed after the duplicate insert is rejected by the unique key.
INSERT_BARRIER=918180000000001002
P "create schema issue18_concurrency;
   create function issue18_concurrency.pause_cv_insert()
   returns trigger language plpgsql security definer set search_path = ''
   as \$pause\$
   begin
     perform pg_catalog.pg_advisory_lock($INSERT_BARRIER);
     return new;
   end
   \$pause\$;
   create trigger zz_issue18_pause_cv_insert
   before insert on public.cv_documents
   for each row
   when (new.storage_path = '$REVERSE_PATH')
   execute function issue18_concurrency.pause_cv_insert();" >/dev/null

start_barrier "$INSERT_BARRIER" "INSERT_BARRIER_READY"
PGAPPNAME="issue18-insert-first" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$TMP/insert-first.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-insert-first';
set local role service_role;
insert into public.cv_documents (graduate_id, storage_path, file_type, size_bytes)
values ('$OWNER', '$REVERSE_PATH', 'pdf', 128);
commit;
SQL
B_PID=$!
wait_for_lock_wait "issue18-insert-first"

PGAPPNAME="issue18-delete-after-insert" psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$TMP/delete-after-insert.log" 2>&1 <<SQL &
begin;
set local application_name = 'issue18-delete-after-insert';
select pg_catalog.set_config('request.jwt.claims',
  jsonb_build_object('sub', '$OWNER', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.delete_cv_document('$REVERSE_DOC');
reset role;
commit;
SQL
A_PID=$!
wait_for_lock_wait "issue18-delete-after-insert"
release_barrier "INSERT_BARRIER_RELEASED"

set +e
wait "$B_PID"; B_STATUS=$?
wait "$A_PID"; A_STATUS=$?
set -e
A_PID=""; B_PID=""
check "insert-first delete transaction commits after unique conflict" "0" "$A_STATUS"
check "insert-first duplicate registration is rejected by storage_path uniqueness" "3" "$B_STATUS"
grep -qi "duplicate key value violates unique constraint" "$TMP/insert-first.log" \
  && check "insert-first rejection is the existing unique constraint" "1" "1" \
  || check "insert-first rejection is the existing unique constraint" "1" "0"
check "insert-first path has one queue tombstone" "1" \
  "$(P "select count(*) from private.cv_cleanup_queue where storage_path = '$REVERSE_PATH'")"
check "insert-first path has no live metadata" "0" \
  "$(P "select count(*) from public.cv_documents where storage_path = '$REVERSE_PATH'")"
check "neither ordering commits a queue/live-metadata overlap" "0" \
  "$(P "select count(*) from public.cv_documents d join private.cv_cleanup_queue q on q.storage_path = d.storage_path where q.storage_path in ('$DELETE_PATH', '$REVERSE_PATH')")"

echo "CV CLEANUP CONCURRENCY PASSED"
