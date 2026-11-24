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
const TESTS = ["01_register_for_event", "02_rpc_rules", "03_rls_security", "04_storage_cv_ownership", "05_recommendation_cache"];

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
  put("supabase", `case "$1 $2" in
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
  assert.equal(MIGS.length, 10);
});
test("a migration missing from `db reset` output fails the run", () => {
  const r = run({ FAKE_MISSING: "0010_hide_saved_item_helper_from_api.sql" });
  assert.equal(r.status, 1); assert.ok(out(r).includes("does not show 0010_hide_saved_item_helper_from_api.sql as applied"));
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
