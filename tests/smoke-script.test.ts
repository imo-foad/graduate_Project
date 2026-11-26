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

  // Cleanup still runs, and it runs after the failing reset.
  const invoked = existsSync(calls) ? readFileSync(calls, "utf8") : "";
  assert.match(invoked, /supabase db reset/);
  assert.match(invoked, /supabase stop/);
});
