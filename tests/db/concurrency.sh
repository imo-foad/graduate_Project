#!/usr/bin/env bash
# Concurrency proof for register_for_event / apply_for_job against a REAL PostgreSQL (local Supabase).
# Requires: psql, DB_URL (default: local supabase). Refuses to run against non-local hosts.
# Usage: bash tests/db/concurrency.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
# guard: parsed host must be exactly 127.0.0.1 / localhost / ::1 (a substring check would accept user@remote URLs)
command -v node >/dev/null || { echo "REFUSING: node is required to validate DB_URL" >&2; exit 2; }
node "$ROOT/scripts/assert-local-db.mjs" "$DB_URL" || exit 2
command -v psql >/dev/null || { echo "psql not found" >&2; exit 2; }
TAG="conc$(date +%s)"; N=12; CAP=3; FAILS=0
P() { psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }
# prerequisites: migrations + seeds must already be loaded (fail loudly instead of reporting meaningless results)
[ "$(P -c "select count(*) from public.skills where id in ('GIT','SQL')")" = "2" ] || { echo "PREREQUISITE MISSING: seed skills GIT/SQL (run scripts/run-db-tests.sh)" >&2; exit 2; }
[ "$(P -c "select count(*) from pg_proc where proname = 'save_recommendations' and pronargs = 4")" = "1" ] || { echo "PREREQUISITE MISSING: migration 0007" >&2; exit 2; }
check() { # description expected actual
  if [ "$2" = "$3" ]; then echo "PASS  $1 (=$3)"; else echo "FAIL  $1 expected=$2 actual=$3"; FAILS=$((FAILS+1)); fi
}
cleanup() { P -c "delete from auth.users where email like '${TAG}-%@tests.local'; delete from public.opportunities where seed_key like '${TAG}-%';" >/dev/null 2>&1; }
trap cleanup EXIT

# --- setup (as postgres): N users, two events (no waitlist / waitlist), one job
P <<SQL
insert into auth.users (id, aud, role, email, raw_user_meta_data)
select gen_random_uuid(), 'authenticated', 'authenticated', '${TAG}-' || g || '@tests.local', jsonb_build_object('full_name', 'c' || g)
  from generate_series(1, ${N}) g;
insert into public.opportunities (seed_key, type, title, status, deadline, capacity, waitlist_enabled, attendance_mode) values
  ('${TAG}-nowait', 'EVENT', 'race nowait', 'ACTIVE', now() + interval '3 days', ${CAP}, false, 'ONLINE'),
  ('${TAG}-wait',   'EVENT', 'race wait',   'ACTIVE', now() + interval '3 days', ${CAP}, true,  'ONLINE'),
  ('${TAG}-job',    'JOB',   'race job',    'ACTIVE', now() + interval '3 days', null,   false, 'ONLINE');
SQL
opp() { P -c "select id from public.opportunities where seed_key = '${TAG}-$1'"; }
usr() { P -c "select id from auth.users where email = '${TAG}-$1@tests.local'"; }
as_user() { # uid sql -> prints result or ERROR:<message>
  psql "$DB_URL" -X -q -t -A -c "begin; select set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); set local role authenticated; $2; commit;" 2>&1 | grep -v '^$' || true
}
NOWAIT=$(opp nowait); WAIT=$(opp wait); JOB=$(opp job)

# --- 1. N different users race for CAP seats, no waitlist
OUT=$(mktemp); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$(usr $i)" "select (public.register_for_event('$NOWAIT')).status" >>"$OUT" ) & PIDS+=($!)
done; wait "${PIDS[@]}"
check "no-waitlist: REGISTERED rows == capacity" "$CAP" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$NOWAIT' and status='REGISTERED'")"
check "no-waitlist: registered_count == capacity" "$CAP" "$(P -c "select registered_count from public.opportunities where id='$NOWAIT'")"
check "no-waitlist: rejected callers got EVENT_FULL" "$((N-CAP))" "$(grep -c 'EVENT_FULL' "$OUT")"

# --- 2. same race with waitlist
OUT=$(mktemp); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$(usr $i)" "select (public.register_for_event('$WAIT')).status" >>"$OUT" ) & PIDS+=($!)
done; wait "${PIDS[@]}"
check "waitlist: REGISTERED == capacity" "$CAP" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$WAIT' and status='REGISTERED'")"
check "waitlist: WAITLISTED == N-capacity" "$((N-CAP))" "$(P -c "select count(*) from public.event_registrations where opportunity_id='$WAIT' and status='WAITLISTED'")"
check "waitlist: registered_count == capacity" "$CAP" "$(P -c "select registered_count from public.opportunities where id='$WAIT'")"

# --- 3. one user double-clicks 6 times: exactly one row, others ALREADY_*
U=$(usr 1); OUT=$(mktemp); PIDS=()
P -c "delete from public.event_registrations where opportunity_id='$NOWAIT'; update public.opportunities set registered_count=0 where id='$NOWAIT'"
for i in 1 2 3 4 5 6; do ( as_user "$U" "select (public.register_for_event('$NOWAIT')).status" >>"$OUT" ) & PIDS+=($!); done; wait "${PIDS[@]}"
check "double-click: exactly one row for the user" "1" "$(P -c "select count(*) from public.event_registrations where graduate_id='$U' and opportunity_id='$NOWAIT'")"
check "counter equals REGISTERED rows after races" "0" "$(P -c "select count(*) from public.opportunities o where o.seed_key like '${TAG}-%' and o.registered_count <> (select count(*) from public.event_registrations r where r.opportunity_id=o.id and r.status='REGISTERED')")"

# --- 4. concurrent apply by one user: exactly one application
OUT=$(mktemp); PIDS=()
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
OUT=$(mktemp); PIDS=()
for i in $(seq 1 $N); do
  ( as_user "$SOCIAL_UID" "select public.like_social_post('$SOCIAL_POST')" >>"$OUT" ) & PIDS+=($!)
done
wait "${PIDS[@]}"
check "Social Feed like race: exactly one like edge" "1" "$(P -c "select count(*) from public.social_post_likes where post_id='$SOCIAL_POST' and graduate_id='$SOCIAL_UID'")"
check "Social Feed like race: all competing requests rejected as ALREADY_LIKED" "$((N-1))" "$(grep -c 'ALREADY_LIKED' "$OUT")"
rm -f "$OUT"

# --- 9. concurrent provider callbacks reusing one event id with different payloads.
SCH_ADMIN=$(node -e 'console.log(require("crypto").randomUUID())')
SCH_GRAD=$(node -e 'console.log(require("crypto").randomUUID())')
SCH_OPP=""
SCH_APP=""
cleanup_scholarship() {
  if [ -n "${SCH_OPP:-}" ]; then
    P -c "delete from private.scholarship_provider_mappings where opportunity_id='$SCH_OPP'" >/dev/null 2>&1 || true
  fi
  P -c "delete from auth.users where id in ('$SCH_ADMIN','$SCH_GRAD')" >/dev/null 2>&1 || true
  P -c "delete from public.opportunities where seed_key='${TAG}-scholarship-race'" >/dev/null 2>&1 || true
}
trap 'cleanup_scholarship; cleanup' EXIT
P <<SQL
insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('$SCH_ADMIN','authenticated','authenticated','${TAG}-scholar-admin@tests.local',now(),'{"full_name":"Scholarship Admin"}'),
 ('$SCH_GRAD','authenticated','authenticated','${TAG}-scholar-grad@tests.local',now(),'{"full_name":"Scholarship Graduate"}');
insert into private.platform_admins(user_id,is_active) values ('$SCH_ADMIN',true);
insert into public.opportunities(seed_key,type,title,status,deadline,attendance_mode,is_sample)
values ('${TAG}-scholarship-race','SCHOLARSHIP','Provider callback race','ACTIVE',
        now() + interval '5 days','ONLINE',false);
SQL
SCH_OPP=$(P -c "select id from public.opportunities where seed_key='${TAG}-scholarship-race'")
as_user "$SCH_ADMIN" "select public.configure_scholarship_provider_mapping('$SCH_OPP','PROVIDER_RACE','remote-race',true)" >/dev/null
SCH_APP=$(as_user "$SCH_GRAD" "select (public.apply_for_scholarship('$SCH_OPP')).id" | grep -Eio '[0-9a-f-]{36}' | tail -n1)
[ -n "$SCH_APP" ] || { echo "PREREQUISITE FAILED: scholarship race application was not created" >&2; exit 2; }
svc_scholar() {
  psql "$DB_URL" -X -q -t -A -c "begin;
    select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true);
    set local role service_role;
    $1;
    commit;" 2>&1 | sed '/^$/d' || true
}
svc_scholar "select application_id from public.claim_scholarship_delivery('$SCH_APP',1)" >/dev/null
SCH_OUTBOX=$(P -c "select id from private.scholarship_delivery_outbox where application_id='$SCH_APP'")
svc_scholar "select (public.complete_scholarship_delivery('$SCH_OUTBOX','race-provider-ref',202,null)).id" >/dev/null
SCH_DIGEST_A=$(printf 'race-payload-a' | sha256sum | awk '{print $1}')
SCH_DIGEST_B=$(printf 'race-payload-b' | sha256sum | awk '{print $1}')
OUT=$(mktemp); PIDS=()
(
  svc_scholar "select public.process_scholarship_provider_event(
    'PROVIDER_RACE','same-event-id','race-provider-ref','IN_REVIEW','event A','$SCH_DIGEST_A')"
) >>"$OUT" & PIDS+=($!)
(
  svc_scholar "select public.process_scholarship_provider_event(
    'PROVIDER_RACE','same-event-id','race-provider-ref','REJECTED','event B','$SCH_DIGEST_B')"
) >>"$OUT" & PIDS+=($!)
wait "${PIDS[@]}"
check "provider callback race: only one event ledger row" "1" "$(P -c "select count(*) from private.scholarship_provider_events where provider_key='PROVIDER_RACE' and event_id='same-event-id'")"
check "provider callback race: changed concurrent payload is rejected" "1" "$(grep -c 'PROVIDER_EVENT_ID_CONFLICT' "$OUT")"
check "provider callback race: application ends in the single accepted event state" "1" "$(P -c "select count(*) from public.scholarship_applications where id='$SCH_APP' and status in ('IN_REVIEW','REJECTED')")"
rm -f "$OUT"
cleanup_scholarship
SCH_OPP=""
trap cleanup EXIT

# --- 9. concurrent provider callbacks reusing one event id with different payloads.
CMP_ADMIN=$(node -e 'console.log(require("crypto").randomUUID())')
CMP_GRAD=$(node -e 'console.log(require("crypto").randomUUID())')
CMP_OPP=""
CMP_APP=""
cleanup_competition() {
  if [ -n "${CMP_OPP:-}" ]; then
    P -c "delete from private.competition_provider_mappings where opportunity_id='$CMP_OPP'" >/dev/null 2>&1 || true
  fi
  P -c "delete from auth.users where id in ('$CMP_ADMIN','$CMP_GRAD')" >/dev/null 2>&1 || true
  P -c "delete from public.opportunities where seed_key='${TAG}-competition-race'" >/dev/null 2>&1 || true
}
trap 'cleanup_competition; cleanup' EXIT
P <<SQL
insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('$CMP_ADMIN','authenticated','authenticated','${TAG}-scholar-admin@tests.local',now(),'{"full_name":"Competition Admin"}'),
 ('$CMP_GRAD','authenticated','authenticated','${TAG}-scholar-grad@tests.local',now(),'{"full_name":"Competition Graduate"}');
insert into private.platform_admins(user_id,is_active) values ('$CMP_ADMIN',true);
insert into public.opportunities(seed_key,type,title,status,deadline,attendance_mode,is_sample)
values ('${TAG}-competition-race','COMPETITION','Provider callback race','ACTIVE',
        now() + interval '5 days','ONLINE',false);
SQL
CMP_OPP=$(P -c "select id from public.opportunities where seed_key='${TAG}-competition-race'")
as_user "$CMP_ADMIN" "select public.configure_competition_provider_mapping('$CMP_OPP','PROVIDER_RACE','remote-race',true)" >/dev/null
CMP_APP=$(as_user "$CMP_GRAD" "select (public.apply_for_competition('$CMP_OPP')).id" | grep -Eio '[0-9a-f-]{36}' | tail -n1)
[ -n "$CMP_APP" ] || { echo "PREREQUISITE FAILED: competition race application was not created" >&2; exit 2; }
svc_competition() {
  psql "$DB_URL" -X -q -t -A -c "begin;
    select set_config('request.jwt.claims','{\"role\":\"service_role\"}',true);
    set local role service_role;
    $1;
    commit;" 2>&1 | sed '/^$/d' || true
}
svc_competition "select application_id from public.claim_competition_delivery('$CMP_APP',1)" >/dev/null
CMP_OUTBOX=$(P -c "select id from private.competition_delivery_outbox where application_id='$CMP_APP'")
svc_competition "select (public.complete_competition_delivery('$CMP_OUTBOX','race-provider-ref',202,null)).id" >/dev/null
CMP_DIGEST_A=$(printf 'race-payload-a' | sha256sum | awk '{print $1}')
CMP_DIGEST_B=$(printf 'race-payload-b' | sha256sum | awk '{print $1}')
OUT=$(mktemp); PIDS=()
(
  svc_competition "select public.process_competition_provider_event(
    'PROVIDER_RACE','same-event-id','race-provider-ref','IN_REVIEW','event A','$CMP_DIGEST_A')"
) >>"$OUT" & PIDS+=($!)
(
  svc_competition "select public.process_competition_provider_event(
    'PROVIDER_RACE','same-event-id','race-provider-ref','IN_REVIEW','event B','$CMP_DIGEST_B')"
) >>"$OUT" & PIDS+=($!)
wait "${PIDS[@]}"
check "provider callback race: only one event ledger row" "1" "$(P -c "select count(*) from private.competition_provider_events where provider_key='PROVIDER_RACE' and event_id='same-event-id'")"
check "provider callback race: changed concurrent payload is rejected" "1" "$(grep -c 'PROVIDER_EVENT_ID_CONFLICT' "$OUT")"
check "provider callback race: application ends in the single accepted event state" "1" "$(P -c "select count(*) from public.competition_applications where id='$CMP_APP' and status = 'IN_REVIEW'")"
rm -f "$OUT"
cleanup_competition
CMP_OPP=""
trap cleanup EXIT


echo; [ $FAILS -eq 0 ] && echo "ALL CONCURRENCY CHECKS PASSED" || { echo "$FAILS CHECK(S) FAILED"; exit 1; }
