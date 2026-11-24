import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertLocalDbUrl } from "../scripts/assert-local-db.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const CLEAN = {};
const ok = (u: string) => assertLocalDbUrl(u, CLEAN);
const bad = (u: string, why?: RegExp) => assert.throws(() => ok(u), why ?? /./, u);

test("REGRESSION: the old substring check accepted these remote URLs; the new guard rejects them", () => {
  const oldCheck = (u: string) => /127\.0\.0\.1|localhost/.test(u);
  const attacks = [
    "postgresql://127.0.0.1:pw@db.qikqbvohqjblbcysbvel.supabase.co:5432/postgres", // 127.0.0.1 as username
    "postgresql://postgres:127.0.0.1@db.qikqbvohqjblbcysbvel.supabase.co:5432/postgres", // ... as password
    "postgresql://postgres:pw@db.qikqbvohqjblbcysbvel.supabase.co:5432/127.0.0.1", // ... as database name
    "postgresql://postgres:pw@db.qikqbvohqjblbcysbvel.supabase.co:5432/postgres?application_name=localhost",
    "postgresql://localhost.evil.com:5432/postgres", "postgresql://127.0.0.1.evil.com:5432/postgres",
  ];
  for (const a of attacks) { assert.equal(oldCheck(a), true, `old check should (wrongly) accept ${a}`); bad(a); }
});

test("accepts exactly the local hosts with an explicit valid port", () => {
  assert.deepEqual(ok("postgresql://postgres:postgres@127.0.0.1:54322/postgres"), { host: "127.0.0.1", port: 54322 });
  assert.equal(ok("postgres://postgres:postgres@localhost:54322/postgres").host, "localhost");
  assert.equal(ok("postgresql://postgres:postgres@[::1]:54322/postgres").host, "[::1]");
  ok("postgresql://postgres:postgres@127.0.0.1:54322/postgres?sslmode=disable&connect_timeout=5");
});

test("rejects every non-local host", () => {
  for (const h of ["db.qikqbvohqjblbcysbvel.supabase.co", "aws-0-eu-central-1.pooler.supabase.com", "127.0.0.2", "0.0.0.0",
                   "10.0.0.5", "LOCALHOST", "localhost.", "[::2]", "[::ffff:127.0.0.1]", "127.1", "2130706433", "example.com"])
    bad(`postgresql://postgres:pw@${h}:5432/postgres`, /not local|malformed/);
});

test("rejects malformed, incomplete or tricky URLs", () => {
  for (const u of ["", "   ", "not a url", "postgresql://", "postgresql:///postgres", "http://127.0.0.1:54322/postgres",
                   "postgresql://127.0.0.1/postgres", "postgresql://127.0.0.1:0/postgres", "postgresql://127.0.0.1:80/postgres",
                   "postgresql://127.0.0.1:70000/postgres", "postgresql://127.0.0.1:abc/postgres",
                   "postgresql://127.0.0.1:54322,db.x.supabase.co:5432/postgres", " postgresql://127.0.0.1:54322/postgres",
                   "postgresql://127.0.0.1:54322/postgres\n"]) bad(u);
  assert.throws(() => assertLocalDbUrl(undefined as unknown as string, CLEAN));
});

test("rejects libpq query parameters that can redirect the connection", () => {
  for (const q of ["host=db.x.supabase.co", "hostaddr=1.2.3.4", "service=prod", "options=-c%20x=1", "dbname=other", "passfile=/x"])
    bad(`postgresql://postgres:pw@127.0.0.1:54322/postgres?${q}`, /query parameter/);
  bad("postgresql:///postgres?host=/var/run/postgresql", /not local|port/);
});

test("rejects environment variables that can override the host", () => {
  for (const v of ["PGHOST", "PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE"])
    assert.throws(() => assertLocalDbUrl("postgresql://postgres:pw@127.0.0.1:54322/postgres", { [v]: "x" }), /environment variable/);
});

function fakeBin(names: string[]) {
  const dir = mkdtempSync(join(tmpdir(), "fakebin-"));
  const marker = join(dir, "TOOL_WAS_CALLED");
  for (const n of names) { writeFileSync(join(dir, n), `#!/bin/sh\necho "$0 $*" >> "${marker}"\nexit 0\n`); chmodSync(join(dir, n), 0o755); }
  return { dir, marker };
}
const REMOTE = "postgresql://postgres:pw@db.qikqbvohqjblbcysbvel.supabase.co:5432/postgres";
const TRICKY = "postgresql://127.0.0.1:pw@db.qikqbvohqjblbcysbvel.supabase.co:5432/postgres";

for (const [script, tools] of [["scripts/run-db-tests.sh", ["supabase", "psql", "docker", "npm"]], ["tests/db/concurrency.sh", ["psql", "supabase"]]] as const) {
  test(`${script} refuses remote/tricky DB_URL with exit 2 BEFORE running any tool`, () => {
    for (const url of [REMOTE, TRICKY, "garbage"]) {
      const { dir, marker } = fakeBin([...tools]);
      const r = spawnSync("bash", [join(ROOT, script)], { env: { PATH: `${dir}:${process.env.PATH}`, DB_URL: url, HOME: process.env.HOME ?? "/tmp" }, encoding: "utf8", cwd: ROOT });
      assert.equal(r.status, 2, `${script} with ${url}: ${r.stdout}${r.stderr}`);
      assert.match(r.stderr + r.stdout, /REFUSING/);
      assert.equal(existsSync(marker), false, `a tool was invoked for ${url}`);
    }
  });
}
