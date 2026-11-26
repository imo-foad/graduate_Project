// Tests the CONTROL FLOW of scripts/run-db-tests.sh with fake supabase/psql/docker binaries.
// This is NOT database evidence: it proves the runner fails loudly instead of skipping or ignoring problems.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const MIGS = readdirSync(join(ROOT, "supabase/migrations")).filter((f) => f.endsWith(".sql")).sort();
const VERSIONS = MIGS.map((m) => m.split("_")[0]).join(",");
const SKILLS = JSON.parse(readFileSync(join(ROOT, "fixtures/skills.json"), "utf8")).length;
const OPPS = JSON.parse(readFileSync(join(ROOT, "fixtures/opportunities.json"), "utf8")).length;
const TESTS = ["01_register_for_event", "02_rpc_rules", "03_rls_security", "04_storage_cv_ownership", "05_recommendation_cache", "06_company_workflow", "07_admin_company_controls", "08_cv_parse_lifecycle", "09_cv_intelligence", "10_cancelled_scope_guard", "12_social_feed", "13_social_moderation_rate_limits", "14_secure_graduate_onboarding", "15_three_type_scope", "16_cv_cleanup_queue", "17_recommendation_availability", "18_identity_and_organizations", "19_product_lifecycle"];

function fakeBin() {
  const dir = mkdtempSync(join(tmpdir(), "fake-"));
  const put = (name: string, body: string) => { writeFileSync(join(dir, name), `#!/bin/bash\n${body}\n`); chmodSync(join(dir, name), 0o755); };
  put("docker", `exit 0`);
  put("psql", `case "$*" in *--version*) echo "psql (PostgreSQL) 16.0"; exit 0;; esac
for a in "$@"; do [ "$a" = "-f" ] && exit 0; done
q=""; while [ $# -gt 0 ]; do [ "$1" = "-c" ] && { q="$2"; break; }; shift; done
case "$q" in
  "select 1") echo 1;; "show server_version") echo "17.12";;
  *string_agg*) echo "$FAKE_MIGRATIONS";; *"from public.skills"*) echo "$FAKE_SKILLS";;
  *"from public.opportunities"*) echo "$FAKE_OPPS";; *"opportunity_skills os left join"*) echo 0;; *) echo "";; esac`);
  put("supabase", `if [[ "$1 $2 $3" == "test db database/15_three_type_scope.test.sql" ]]; then
  echo "supabase/tests/database/15_three_type_scope.test.sql .. ok"
  echo "Result: PASS"
  exit \${FAKE_TEST15_EXIT:-0}
fi
case "$1 $2" in
  "--version "*) echo "2.0.0";;
  "start "*) echo "Started supabase local development setup.";;
  "db reset") for f in ${MIGS.map((m) => `"${m}"`).join(" ")}; do [ "$f" = "$FAKE_MISSING" ] || echo "Applying migration $f..."; done;;
  "test db") for t in ${TESTS.join(" ")}; do [ "$t" = "$FAKE_TEST_MISSING" ] || echo "supabase/tests/database/$t.test.sql .. ok"; done; echo "Result: PASS"; exit \${FAKE_TEST_EXIT:-0};;
esac`);
  put("bash", `case "$1" in *concurrency.sh) echo "ALL CONCURRENCY CHECKS PASSED"; exit \${FAKE_CONC_EXIT:-0};; *run-local-integrations.sh) echo "LOCAL HTTP INTEGRATION PASSED: 20 checks"; exit \${FAKE_INTEGRATION_EXIT:-0};; esac\nexec /bin/bash "$@"`);
  return dir;
}
function run(over: Record<string, string> = {}) {
  const dir = fakeBin();
  const env = { PATH: `${dir}:${process.env.PATH}`, HOME: process.env.HOME ?? "/tmp", FAKE_MIGRATIONS: VERSIONS, FAKE_SKILLS: String(SKILLS), FAKE_OPPS: String(OPPS), ...over };
  return spawnSync("/bin/bash", [join(ROOT, "scripts/run-db-tests.sh")], { env, encoding: "utf8", cwd: ROOT });
}
const out = (r: ReturnType<typeof run>) => r.stdout + r.stderr;

test("happy path (fake tools): every phase runs and the script reports success", () => {
  const r = run();
  assert.equal(r.status, 0, out(r));
  for (const m of ["=== A.", "=== B.", "=== C.", "=== D.", "=== E.", "=== F.", "LOCAL HTTP INTEGRATION PASSED", "DB TESTS PASSED", `migrations applied: ${VERSIONS}`]) assert.ok(out(r).includes(m), m);
  assert.ok(MIGS.length > 0, "at least one dynamically discovered migration must be present");
});
test("migration discovery validates dynamic unique/increasing versions without a fixed total", () => {
  const runner = readFileSync(join(ROOT, "scripts/run-db-tests.sh"), "utf8");
  assert.match(runner, /MIGRATIONS=\(supabase\/migrations\/\*\.sql\)/);
  assert.match(runner, /PREVIOUS_VERSION/);
  assert.doesNotMatch(runner, /-ge\s+\d+/);
  assert.doesNotMatch(runner, /through\s+\d{4}/);
});
test("focused Test 15 runs independently and fails the DB runner when it fails", () => {
  const r = run({ FAKE_TEST15_EXIT: "1" });
  assert.equal(r.status, 1, out(r));
  assert.ok(out(r).includes("=== D1. focused Test 15"));
  assert.ok(out(r).includes("database/15_three_type_scope.test.sql"));
  assert.ok(!out(r).includes("=== D2. full pgTAP suite"), "full suite must not hide the focused failure");
});
test("the Social Feed migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0017_social_feed.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0017_social_feed.sql as applied"));
});
test("the Social Moderation and Rate Limits migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0018_social_moderation_rate_limits.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0018_social_moderation_rate_limits.sql as applied"));
});
test("the competition migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0016_competition_applications.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0016_competition_applications.sql as applied"));
});
test("the scholarship migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0015_scholarship_applications.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0015_scholarship_applications.sql as applied"));
});
test("the internal Scholarship management migration is mandatory in db reset output (historical, retained)", () => {
  const r = run({ FAKE_MISSING: "0020_internal_scholarship_management.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0020_internal_scholarship_management.sql as applied"));
});
test("the cancelled-scope migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0025_cancel_scholarship_and_competition.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0025_cancel_scholarship_and_competition.sql as applied"));
});
test("the graduate-invitation duplicate guard migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0023_graduate_invitation_duplicate_guard.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0023_graduate_invitation_duplicate_guard.sql as applied"));
});
test("the external Scholarship delivery migration is mandatory in db reset output", () => {
  const r = run({ FAKE_MISSING: "0021_scholarship_delivery_review.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0021_scholarship_delivery_review.sql as applied"));
});
test("a migration missing from `db reset` output fails the run", () => {
  const r = run({ FAKE_MISSING: "0014_cv_intelligence_recommendations.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0014_cv_intelligence_recommendations.sql as applied"));
});
test("a migration missing from the migration table fails the run", () => {
  const r = run({ FAKE_MIGRATIONS: VERSIONS.replace(",0010", "") });
  assert.equal(r.status, 1); assert.match(out(r), /migration table has/);
});
test("wrong seed counts fail the run", () => {
  assert.equal(run({ FAKE_SKILLS: "3" }).status, 1);
  assert.equal(run({ FAKE_OPPS: "3" }).status, 1);
});
test("a pgTAP file that never ran fails the run (no silent skip)", () => {
  for (const t of TESTS) {
    const r = run({ FAKE_TEST_MISSING: t });
    assert.equal(r.status, 1, t); assert.match(out(r), new RegExp(`does not show ${t}\\.test\\.sql`));
  }
});
test("pgTAP failure exit code fails the run", () => assert.notEqual(run({ FAKE_TEST_EXIT: "1" }).status, 0));
test("concurrency failure fails the run", () => assert.notEqual(run({ FAKE_CONC_EXIT: "1" }).status, 0));

test("local HTTP integration failure fails the database runner", () => assert.notEqual(run({ FAKE_INTEGRATION_EXIT: "1" }).status, 0));
