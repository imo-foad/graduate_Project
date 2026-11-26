import { test } from "node:test";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { buildSeed, validateFixtures, validateUniversityFixtures, q } from "../scripts/build-seed.mjs";
import { assertLocalSupabaseApiUrl, buildCreatePhoneUserRequest, provisionUniversityAccounts } from "../scripts/provision-university-demo-users.mjs";
import { assertLocalUniversitySeedTargets } from "../scripts/seed-university-demo.mjs";
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
  assert.deepEqual(Object.keys(out), ["01_skills.sql", "02_catalogue.sql", "03_demo_profiles.sql", "04_university_accounts.sql"]);
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

const university = JSON.parse(readFileSync(new URL("../fixtures/university-accounts.json", import.meta.url), "utf8"));

test("university fixture has 20 students, 10 faculty, 10 admins and 20 distinct GPA values", () => {
  assert.deepEqual(validateUniversityFixtures(university), []);
  assert.equal(university.students.length,20);
  assert.equal(university.faculty.length,10);
  assert.equal(university.administrators.length,10);
  assert.equal(new Set(university.students.map((s: any)=>s.gpa)).size,20);
  assert.ok(university.students.every((s: any)=>s.gpa_scale===4.0 && s.gpa>=0 && s.gpa<=4));
  assert.equal(new Set(university.students.map((s: any)=>s.academic_track)).size,7);
});

test("university fixture validation rejects invalid GPA, track and duplicate reference", () => {
  const invalid=structuredClone(university);
  invalid.students[0].gpa=4.25;
  invalid.students[1].academic_track="Cancelled Track";
  invalid.students[2].institution_ref=invalid.students[0].institution_ref;
  const errors=validateUniversityFixtures(invalid);
  assert.ok(errors.some((e: string)=>e.includes("GPA")));
  assert.ok(errors.some((e: string)=>e.includes("academic track")));
  assert.ok(errors.some((e: string)=>e.includes("institution_ref")));
});

test("new synthetic Auth request creates phone-only accounts without SMS delivery", () => {
  const req=buildCreatePhoneUserRequest("http://127.0.0.1:54321","local-key",university.students[0],"demo-password-123");
  assert.equal(req.url,"http://127.0.0.1:54321/auth/v1/admin/users");
  const body=JSON.parse(req.init.body as string);
  assert.equal(body.phone,university.students[0].phone);
  assert.equal(body.phone_confirm,true);
  assert.equal(body.user_metadata.synthetic_seed,true);
  assert.equal(Object.hasOwn(body,"email"),false);
});

test("non-local university Auth URL is rejected before the first network request", async () => {
  let requests=0;
  await assert.rejects(provisionUniversityAccounts({
    supabaseUrl:"https://demo-project.supabase.co",serviceRoleKey:"not-real",
    password:"synthetic-demo-password",accounts:university,
    fetchImpl:async()=>{requests+=1;throw new Error("network call must not happen");},
  }),/REFUSING non-local/);
  assert.equal(requests,0);
  assert.throws(()=>assertLocalSupabaseApiUrl("http://10.0.0.12:54321"),/REFUSING non-local/);
  assert.throws(()=>assertLocalSupabaseApiUrl("https://127.0.0.1:54321"),/REFUSING non-local/);
  assert.equal(assertLocalSupabaseApiUrl("http://localhost:54321"),"http://localhost:54321");
});

test("university seed SQL is guarded, transactional, deterministic and credential-free", () => {
  const sql=buildSeed()["04_university_accounts.sql"];
  assert.match(sql,/^begin;$/m);
  assert.match(sql,/^commit;$/m);
  assert.match(sql,/SYNTHETIC_UNIVERSITY_SEED_REQUIRES_LOCAL_GUARD/);
  assert.match(sql,/SYNTHETIC_SEED/);
  assert.match(sql,/private\.platform_admins/);
  assert.match(sql,/student_academic_records/);
  assert.match(sql,/faculty_academic_records/);
  assert.doesNotMatch(sql,/DEMO_PASSWORD|service_role_key|national_id/i);
  assert.equal(buildSeed()["04_university_accounts.sql"],sql);
});

test("both synthetic seed targets reject hosted endpoints before any external operation", () => {
  assert.throws(() => assertLocalUniversitySeedTargets(
    "http://localhost:54321", "postgresql://postgres:secret@db.example.supabase.co:5432/postgres", {}
  ), /not local/);
  assert.throws(() => assertLocalUniversitySeedTargets(
    "https://localhost:54321", "postgresql://postgres:postgres@127.0.0.1:54322/postgres", {}
  ), /REFUSING non-local/);
  assert.deepEqual(
    assertLocalUniversitySeedTargets(
      "http://127.0.0.1:54321","postgresql://postgres:postgres@127.0.0.1:54322/postgres",{}
    ),
    {apiBase:"http://127.0.0.1:54321",dbTarget:{host:"127.0.0.1",port:54322}}
  );
});
