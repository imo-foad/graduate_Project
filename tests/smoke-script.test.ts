import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

test("REGRESSION: the university smoke script fails when supabase db reset fails", () => {
  const bin = mkdtempSync(join(tmpdir(), "smoke-bin-"));
  const calls = join(bin, "calls.log");
  const writeFake = (name: string, body: string) => {
    const file = join(bin, name);
    writeFileSync(file, body);
    chmodSync(file, 0o755);
  };

  // `supabase db reset` fails; cleanup must not convert that failure into success.
  writeFake("supabase", `#!/usr/bin/env bash
printf 'supabase %s\\n' "$*" >> ${JSON.stringify(calls)}
case "$1" in
  start) exit 0 ;;
  db) exit 7 ;;
  stop) exit 0 ;;
  *) exit 0 ;;
esac
`);
  writeFake("docker", "#!/usr/bin/env bash\nexit 0\n");
  writeFake("psql", "#!/usr/bin/env bash\nexit 0\n");
  writeFake("curl", "#!/usr/bin/env bash\nexit 0\n");

  const result = spawnSync("bash", [join(ROOT, "scripts/run-university-seed-smoke.sh")], {
    cwd: ROOT,
    encoding: "utf8",
    env: { ...process.env, PATH: `${bin}:${process.env.PATH ?? ""}` },
  });

  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  assert.notEqual(result.status, 0, `smoke script must fail, got status ${result.status}\n${output}`);
  assert.match(output, /SMOKE RESULT: FAIL/);
  assert.match(output, /cleanup started \(original exit status: 7\)/);

  // The artifact log must exist and contain the reset failure, even though setup failed.
  const logFile = join(ROOT, ".ci-logs", "university-seed-smoke.log");
  assert.ok(existsSync(logFile), "smoke artifact log must be created before operations begin");
  assert.ok(readFileSync(logFile, "utf8").length > 0, "smoke artifact log must not be empty");
  assert.match(readFileSync(logFile, "utf8"), /SMOKE RESULT: FAIL/,
    "the terminal result marker must be flushed into the artifact log before exit");

  // Cleanup still runs, and it runs after the failing reset.
  const invoked = existsSync(calls) ? readFileSync(calls, "utf8") : "";
  assert.match(invoked, /supabase db reset/);
  assert.match(invoked, /supabase stop/);
});

test("GitHub Actions propagates the university smoke exit code and requires its terminal PASS marker", () => {
  const workflow = readFileSync(join(ROOT, ".github/workflows/backend-tests.yml"), "utf8");
  assert.match(workflow, /run: bash scripts\/run-university-seed-smoke\.sh\n/);
  assert.doesNotMatch(workflow, /run: bash scripts\/run-university-seed-smoke\.sh[^\n]*\|\s*tee/);
  assert.match(workflow, /grep -Fxq "SMOKE RESULT: PASS" \.ci-logs\/university-seed-smoke\.log/);
  assert.match(workflow, /grep -q "Auth first pass:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "First-pass counts:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "Second-pass counts:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "\^UNIVERSITY DATASET HTTP INTEGRATION PASSED:" \.ci-logs\/university-dataset-integration\.log/);
  assert.match(workflow, /university-dataset-integration\.log/);
});

test("the smoke workflow does not hide script failures behind an outer tee pipeline", () => {
  const workflow = readFileSync(join(ROOT, ".github/workflows/backend-tests.yml"), "utf8");
  assert.match(workflow, /run: bash scripts\/run-university-seed-smoke\.sh\n/);
  assert.doesNotMatch(workflow, /run: bash scripts\/run-university-seed-smoke\.sh[^\n]*\|\s*tee/);
  assert.match(workflow, /grep -Fxq "SMOKE RESULT: PASS" \.ci-logs\/university-seed-smoke\.log/);
  assert.match(workflow, /grep -q "Auth first pass:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "First-pass counts:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "Second-pass counts:" \.ci-logs\/university-seed-apply\.log/);
  assert.match(workflow, /grep -q "\^UNIVERSITY DATASET HTTP INTEGRATION PASSED:" \.ci-logs\/university-dataset-integration\.log/);
  assert.match(workflow, /university-dataset-integration\.log/);
});

test("the smoke script writes its terminal result after closing and joining tee", () => {
  const script = readFileSync(join(ROOT, "scripts/run-university-seed-smoke.sh"), "utf8");
  const closeOutput = script.indexOf("exec 1>&3 2>&4");
  const joinTee = script.indexOf('wait "$TEE_PID" || true', closeOutput);
  const appendMarker = script.indexOf('printf \'%s\\n\' "$marker" >> "$LOG_FILE"', joinTee);
  assert.ok(closeOutput >= 0 && joinTee > closeOutput && appendMarker > joinTee,
    "tee must exit before the terminal result is appended to the artifact");
});


test("the university smoke proves phone/password Auth and RLS over the local HTTP API", () => {
  const script = readFileSync(join(ROOT, "scripts/run-university-seed-smoke.sh"), "utf8");
  const integration = readFileSync(join(ROOT, "tests/integration/university-dataset.integration.mjs"), "utf8");
  const seed = script.indexOf("node scripts/seed-university-demo.mjs");
  const httpIntegration = script.indexOf("node tests/integration/university-dataset.integration.mjs");
  assert.ok(seed >= 0 && httpIntegration > seed, "HTTP integration must run after the 40-account seed");
  assert.match(script, /university-dataset-integration\.log/);
  assert.match(integration, /auth\/v1\/settings/);
  assert.match(integration, /external\?\.phone/);
  assert.match(integration, /phone\/password login failed/);
});


test("CV parser benchmark uses a dedicated account isolated from the CV integration quota", () => {
  const cvIntegration = readFileSync(join(ROOT, "tests/integration/cv-parse.integration.mjs"), "utf8");
  const evaluator = readFileSync(join(ROOT, "scripts/evaluate-cv-parser-local.mjs"), "utf8");
  const cvUsers = [...cvIntegration.matchAll(/const demo[AB] = "(\S+@\S+)"/g)].map((match) => match[1]);
  const benchmarkUser = evaluator.match(/const userEmail = "(\S+@\S+)"/)?.[1];
  assert.ok(benchmarkUser, "CV benchmark must declare its own Auth account");
  assert.ok(!cvUsers.includes(benchmarkUser),
    "CV benchmark must not consume the same per-user CV_PARSE bucket as the focused CV integration");
});


test("CV parsing and rate-limit integration use independent per-user quota buckets", () => {
  const cvIntegration = readFileSync(join(ROOT, "tests/integration/cv-parse.integration.mjs"), "utf8");
  const evaluator = readFileSync(join(ROOT, "scripts/evaluate-cv-parser-local.mjs"), "utf8");
  const rateLimits = readFileSync(join(ROOT, "tests/integration/rate-limits.integration.mjs"), "utf8");
  const cvUsers = [...cvIntegration.matchAll(/const demo[AB] = "(\S+@\S+)"/g)].map((match) => match[1]);
  const benchmarkUser = evaluator.match(/const userEmail = "(\S+@\S+)"/)?.[1];
  const rateLimitUser = rateLimits.match(/email: "(\S+@\S+)"/)?.[1];
  assert.ok(benchmarkUser && rateLimitUser, "each CV test stage must declare its own Auth account");
  assert.equal(new Set([...cvUsers, benchmarkUser, rateLimitUser]).size, cvUsers.length + 2,
    "focused parser integration, parser benchmark and quota test must not share per-user CV_PARSE buckets");
});
