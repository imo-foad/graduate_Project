#!/usr/bin/env bash
# Concurrency proof for register_for_event / apply_for_job against a REAL PostgreSQL (local Supabase).
# Requires: psql, DB_URL (default: local supabase). Refuses to run against non-local hosts.
# Usage: bash tests/db/concurrency.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
# guard: parsed host must be exactly 127.0.0.1 / localhost / ::1 (a substring check would accept user@remote URLs)
command -v node >/dev/null || { echo "REFUSING: node is required to validate DB_URL" >&2; exit 2; }
node "$ROOT/scripts/assert-local-db.mjs" "$DB_URL" || exit 2
command -v psql >/dev/null || { echo "psql not found" >&2; exit 2; }
TAG="conc$(date +%s)"; N=12; CAP=3; FAILS=0
TEMP_FILES=()
P() { psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
count_matches() { local count; count="$(grep -c "$1" "$2" || true)"; printf '%s' "${count:-0}"; }
# prerequisites: migrations + seeds must already be loaded (fail loudly instead of reporting meaningless results)
[ "$(P -c "select count(*) from public.skills where id in ('GIT','SQL')")" = "2" ] || { echo "PREREQUISITE MISSING: seed skills GIT/SQL (run scripts/run-db-tests.sh)" >&2; exit 2; }
[ "$(P -c "select count(*) from pg_proc where proname = 'save_recommendations' and pronargs = 4")" = "1" ] || { echo "PREREQUISITE MISSING: migration 0007" >&2; exit 2; }
check() { # description expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 (=$3)"; else echo "FAIL  $1 expected=$2 actual=$3"; FAILS=$((FAILS+1)); fi
}
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  for temp_file in "${TEMP_FILES[@]}"; do rm -f "$temp_file"; done
  # Best-effort cleanup must never mask the original test result.
  P -c "delete from public.opportunities where seed_key like '${TAG}-%'; delete from auth.users where email like '${TAG}-%@tests.local';" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# --- setup (as postgres): N users, two events (no waitlist / waitlist), one job
P <<SQL
insert into auth.users (id, aud, role, email, raw_user_meta_data)
select gen_random_uuid(), 'authenticated', 'authenticated', '${TAG}-' || g || '@tests.local', jsonb_build_object('full_name', 'c' || g)
  from generate_series(1, ${N}) g;
insert into public.opportunities (seed_key, type, title, status, deadline, capacity, waitlist_enabled, attendance_mode) values
  ('${TAG}-nowait', 'TRAINING', 'race nowait', 'ACTIVE', now() + interval '3 days', ${CAP}, false, 'ONLINE'),
  ('${TAG}-wait',   'TRAINING', 'race wait',   'ACTIVE', now() + interval '3 days', ${CAP}, true,  'ONLINE'),
  ('${TAG}-job',    'JOB',   'race job',    'ACTIVE', now() + interval '3 days', null,   false, 'ONLINE');
SQL
opp() {
  [ "$#" -eq 1 ] || { echo "opp requires one seed suffix" >&2; return 2; }
  P -c "select id from public.opportunities where seed_key = '${TAG}-$1'"
}
usr() {
  [ "$#" -eq 1 ] || { echo "usr requires one user number" >&2; return 2; }
  P -c "select id from auth.users where email = '${TAG}-$1@tests.local'"
}
as_user() { # uid sql -> prints result or ERROR:<message>; expected business errors are captured for assertions.
  [ "$#" -eq 2 ] || { echo "as_user requires a user id and SQL statement" >&2; return 2; }
  psql "$DB_URL" -X -q -t -A -c "begin; select set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); set local role authenticated; $2; commit;" 2>&1 | grep -v '^$' || true
}
NOWAIT=$(opp nowait); WAIT=$(opp wait); JOB=$(opp job)
[ -n "$NOWAIT" ] && [ -n "$WAIT" ] && [ -n "$JOB" ] || {
  echo "PREREQUISITE FAILED: race opportunities were not created (only active TRAINING is registrable)" >&2
  exit 2
}
[ "$(P -c "select count(*) from auth.users where email like '${TAG}-%@tests.local'")" = "$N" ] || {
  echo "PREREQUISITE FAILED: expected $N concurrency users" >&2
  exit 2
}

# --- 1. N different users race for CAP seats, no waitlist
OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$(usr $i)" "select (public.register_for_event('$NOWAIT')).status" >>"$OUT" ) & PIDS+=($!)
done; wait "${PIDS[@]}"
check "no-waitlist: REGISTERED rows == capacity" "$CAP" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$NOWAIT' and status='REGISTERED'")"
check "no-waitlist: registered_count == capacity" "$CAP" "$(P -c "select registered_count from public.opportunities where id='$NOWAIT'")"
check "no-waitlist: rejected callers got EVENT_FULL" "$((N-CAP))" "$(count_matches 'EVENT_FULL' "$OUT")"

# --- 2. same race with waitlist
OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$(usr $i)" "select (public.register_for_event('$WAIT')).status" >>"$OUT" ) & PIDS+=($!)
done; wait "${PIDS[@]}"
check "waitlist: REGISTERED == capacity" "$CAP" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$WAIT' and status='REGISTERED'")"
check "waitlist: WAITLISTED == N-capacity" "$((N-CAP))" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$WAIT' and status='WAITLISTED'")"
check "waitlist: registered_count == capacity" "$CAP" "$(P -c "select registered_count from public.opportunities where id='$WAIT'")"

# --- 3. one user double-clicks 6 times: exactly one row, others ALREADY_*
U=$(usr 1); OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
P -c "delete from public.event_registrations where opportunity_id='$NOWAIT'; update public.opportunities set registered_count=0 where id='$NOWAIT'"
for i in 1 2 3 4 5 6; do ( as_user "$U" "select (public.register_for_event('$NOWAIT')).status" >>"$OUT" ) & PIDS+=($!); done; wait "${PIDS[@]}"
check "double-click: exactly one row for the user" "1" "$(P -c "select count(*) from public.event_registrations where graduate_id='$U' and opportunity_id='$NOWAIT'")"
check "counter equals REGISTERED rows after races" "0" "$(P -c "select count(*) from public.opportunities o where o.seed_key like '${TAG}-%' and o.registered_count <> (select count(*) from public.event_registrations r where r.opportunity_id=o.id and r.status='REGISTERED')")"

# --- 4. concurrent apply by one user: exactly one application
OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
for i in 1 2 3 4 5 6; do ( as_user "$U" "select (public.apply_for_job('$JOB')).status" >>"$OUT" ) & PIDS+=($!); done; wait "${PIDS[@]}"
check "concurrent apply: exactly one application row" "1" "$(P -c "select count(*) from public.applications where graduate_id='$U' and opportunity_id='$JOB'")"
check "concurrent apply: one history row" "1" "$(P -c "select count(*) from public.application_status_history h join public.applications a on a.id=h.application_id where a.graduate_id='$U' and a.opportunity_id='$JOB'")"

# ===== 5-7. recommendation snapshot races (REAL concurrent sessions) =====
RU=$(usr 2); RSKILL_A=GIT; RSKILL_B=SQL
svc() { psql "$DB_URL" -X -q -t -A -c "begin; set local role service_role; $1; commit;" 2>&1 | grep -v '^$' || true; }
ver() { P -c "select profile_version from public.graduate_profiles where profile_id='$RU'"; }
item() { echo "[{\"opportunity_id\":\"$1\",\"score\":80,\"band\":\"HIGH\"}]"; }
P -c "delete from public.recommendations where graduate_id='$RU'; update public.graduate_profiles set recommendations_dirty=true where profile_id='$RU'"
P -c "insert into public.recommendations (graduate_id, opportunity_id, score, band, model_version) values ('$RU','$NOWAIT',66,'GOOD','known')"

# 5. calculation started on an old snapshot; the graduate edits skills; the old save must be rejected
V0=$(ver)
P -c "insert into public.graduate_skills (graduate_id, skill_id, level) values ('$RU','$RSKILL_A',2)"
R=$(svc "select public.save_recommendations('$RU', '$(item $WAIT)'::jsonb, 'conc', $V0)")
check "stale snapshot rejected with STALE_SNAPSHOT" "1" "$(echo "$R" | grep -c STALE_SNAPSHOT)"
check "stale save left the old cache untouched" "known" "$(P -c "select model_version from public.recommendations where graduate_id='$RU'")"
check "stale save did not clear the dirty flag" "t" "$(P -c "select recommendations_dirty from public.graduate_profiles where profile_id='$RU'")"

# 6. a skill edit arriving WHILE a save is in flight must wait for it, then re-dirty the cache (never be overwritten as 'fresh')
V1=$(ver)
( psql "$DB_URL" -X -q -t -A -c "begin; set local role service_role; select public.save_recommendations('$RU', '$(item $WAIT)'::jsonb, 'conc', $V1); select pg_sleep(4); commit;" >/dev/null 2>&1 ) &
SAVER=$!
sleep 1.5
T0=$(date +%s%N)
P -c "insert into public.graduate_skills (graduate_id, skill_id, level) values ('$RU','$RSKILL_B',3)"
T1=$(date +%s%N); wait $SAVER
ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
check "concurrent skill edit waited for the in-flight save (>=1000ms)" "1" "$([ $ELAPSED_MS -ge 1000 ] && echo 1 || echo 0)"
check "newer profile data is NOT marked fresh" "t" "$(P -c "select recommendations_dirty from public.graduate_profiles where profile_id='$RU'")"
check "profile_version advanced after the in-flight save" "$((V1+1))" "$(ver)"
check "the in-flight save itself was stored (it was valid for V1)" "$WAIT" "$(P -c "select opportunity_id from public.recommendations where graduate_id='$RU'")"

# 7. six concurrent saves with the same version and DIFFERENT payloads: result must be exactly one payload, never a mix
V2=$(ver); PIDS=()
for i in 1 2 3 4 5 6; do
  if [ $((i % 2)) -eq 0 ]; then O=$NOWAIT; else O=$WAIT; fi
  ( svc "select public.save_recommendations('$RU', '$(item $O)'::jsonb, 'conc$i', $V2)" >/dev/null ) & PIDS+=($!)
done; wait "${PIDS[@]}"
check "concurrent saves: exactly one row" "1" "$(P -c "select count(*) from public.recommendations where graduate_id='$RU'")"
check "concurrent saves: cache is fresh" "f" "$(P -c "select recommendations_dirty from public.graduate_profiles where profile_id='$RU'")"
check "concurrent saves: row belongs to one of the payloads" "1" "$(P -c "select count(*) from public.recommendations where graduate_id='$RU' and opportunity_id in ('$NOWAIT','$WAIT')")"
check "concurrent saves: version unchanged by saving" "$V2" "$(ver)"


# --- 8. concurrent duplicate Social Feed likes: one private edge, all other callers get ALREADY_LIKED
SOCIAL_UID=$(usr 3)
SOCIAL_POST=$(P -c "insert into public.social_posts (author_id, content) values ('$SOCIAL_UID', '${TAG} social-like-race') returning id")
[ -n "$SOCIAL_POST" ] || { echo "PREREQUISITE FAILED: could not create Social Feed race post" >&2; exit 2; }
OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$SOCIAL_UID" "select public.like_social_post('$SOCIAL_POST')" >>"$OUT" ) & PIDS+=($!)
done
wait "${PIDS[@]}"
check "Social Feed like race: exactly one like edge" "1" "$(P -c "select count(*) from public.social_post_likes where post_id='$SOCIAL_POST' and graduate_id='$SOCIAL_UID'")"
check "Social Feed like race: all competing requests rejected as ALREADY_LIKED" "$((N-1))" "$(count_matches 'ALREADY_LIKED' "$OUT")"
rm -f "$OUT"

# --- 9. cancelled product scope: no role may create a Scholarship opportunity, even concurrently.
OUT=$(mktemp); TEMP_FILES+=("$OUT"); PIDS=()
for i in $(seq 1 $N); do
  ( psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
      "insert into public.opportunities(seed_key,type,title,status,deadline,attendance_mode,is_sample)
       values ('${TAG}-cancelled-race-$i','SCHOLARSHIP','Cancelled scope race','ACTIVE',
               now() + interval '5 days','ONLINE',false)" >>"$OUT" 2>&1 || true ) & PIDS+=($!)
done
wait "${PIDS[@]}"
check "cancelled scope race: every insertion rejected" "$N" "$(count_matches 'CANCELLED_OPPORTUNITY_TYPE' "$OUT")"
check "cancelled scope race: no opportunity row was created" "0" "$(P -c "select count(*) from public.opportunities where seed_key like '${TAG}-cancelled-race-%'")"
rm -f "$OUT"

echo; [ $FAILS -eq 0 ] && echo "ALL CONCURRENCY CHECKS PASSED" || { echo "$FAILS CHECK(S) FAILED"; exit 1; }
