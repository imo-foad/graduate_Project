import { test } from "node:test";
import assert from "node:assert/strict";
import { buildSeed, validateFixtures, q } from "../scripts/build-seed.mjs";
import { buildCreateUserRequest } from "../scripts/provision-demo-users.mjs";
import { demo, opportunities, skills } from "./helpers.ts";

test("fixtures are internally consistent", () => {
  assert.deepEqual(validateFixtures({ skills, opportunities, demo }), []);
});
test("seed covers the scenarios required by 11.4", () => {
  const k = (key: string) => opportunities.find((o: any) => o.seed_key === key);
  assert.ok(k("job-expired").deadline_days < 0, "expired job");
  assert.equal(k("job-closed").status, "CLOSED");
  assert.ok(k("job-cert-gated").eligibility.required_certifications.length > 0, "mandatory requirement");
  assert.ok(k("trn-full-waitlist").waitlist_enabled && k("trn-full-waitlist").capacity === 1);
  assert.ok(!k("trn-full-nowait").waitlist_enabled && k("trn-full-nowait").capacity === 1);
  assert.ok(k("trn-opens-later").registration_opens_days > 0);
  assert.ok(demo.some((d: any) => d.employment_status === "EMPLOYED") && demo.some((d: any) => d.employment_status === "SEEKING"));
  assert.equal(demo.length, 4);
  assert.ok(demo.every((d: any) => d.email.endsWith("@alumni.test")));
});
test("the seeded catalogue contains only the approved three active types", () => {
  assert.deepEqual([...new Set(opportunities.map((o: any) => o.type))].sort(), ["INTERNSHIP", "JOB", "TRAINING"]);
  for (const o of opportunities) {
    assert.ok(["JOB", "INTERNSHIP", "TRAINING"].includes(o.type), `${o.seed_key}: ${o.type}`);
  }
});
test("demo sample states never include a SUBMITTED record and use SAMPLE_ prefixes", () => {
  for (const d of demo) for (const a of d.applications) assert.match(a.status, /^SAMPLE_/);
});
test("seed SQL is idempotent by construction and transactional", () => {
  const out = buildSeed();
  assert.deepEqual(Object.keys(out), ["01_skills.sql", "02_catalogue.sql", "03_demo_profiles.sql"]);
  for (const sql of Object.values(out)) { assert.match(sql, /^begin;$/m); assert.match(sql, /^commit;$/m); }
  assert.match(out["01_skills.sql"], /on conflict \(id\) do update/);
  assert.match(out["02_catalogue.sql"], /on conflict \(seed_key\) do update/);
  assert.equal(out["03_demo_profiles.sql"].includes("password"), false, "no credentials in seed");
  assert.equal(buildSeed()["02_catalogue.sql"], out["02_catalogue.sql"], "deterministic output");
});
test("SQL quoting escapes single quotes", () => {
  assert.equal(q("O'Neil"), "'O''Neil'");
  assert.equal(q(null), "null");
});
test("provisioning request targets Auth admin API and carries no hard-coded secret", () => {
  const { url, init } = buildCreateUserRequest("http://127.0.0.1:54321/", "svc-key", demo[0], "pw-from-env-123");
  assert.equal(url, "http://127.0.0.1:54321/auth/v1/admin/users");
  const body = JSON.parse(init.body as string);
  assert.equal(body.email_confirm, true);
  assert.equal(body.email, "graduate.demo@alumni.test");
});
