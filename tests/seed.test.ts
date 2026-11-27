import { test } from "node:test";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { buildSeed, validateFixtures, validateUniversityFixtures, q } from "../scripts/build-seed.mjs";
import { assertLocalSupabaseApiUrl, buildCreatePhoneUserRequest, canonicalAuthPhone, isValidE164Phone, provisionUniversityAccounts, summarizeAuthCreateFailure } from "../scripts/provision-university-demo-users.mjs";
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
const migrationSql = readFileSync(new URL("../supabase/migrations/0034_synthetic_university_dataset.sql", import.meta.url), "utf8");
const phoneMigrationSql = readFileSync(new URL("../supabase/migrations/0035_restore_e164_auth_phone.sql", import.meta.url), "utf8");
const count = (haystack: string, needle: string) => haystack.split(needle).length - 1;

test("all 40 synthetic phone values satisfy the exact database E.164 constraint and are unique", () => {
  const phones = [...university.students, ...university.faculty, ...university.administrators]
    .map((account: any) => account.phone);
  assert.equal(phones.length, 40);
  assert.equal(new Set(phones).size, 40);
  assert.ok(phones.every((phone: string) => isValidE164Phone(phone)),
    "all 40 student/faculty/admin phones must satisfy the same E.164 rule");
  assert.equal(count(migrationSql, "add constraint profiles_phone_format_check"), 1,
    "exactly one phone-format constraint is added");
  assert.ok(migrationSql.includes("left(phone, 1) = '+'"), "database requires a literal leading plus");
  assert.ok(migrationSql.includes("length(phone) between 9 and 16"), "database length bounds must be explicit");
  assert.ok(migrationSql.includes("substring(phone from 2) ~ '^[1-9][0-9]{7,14}$'"),
    "database requires 8..15 digits after plus, beginning with a non-zero digit");
});
test("migration 0034 defines each academic structure exactly once", () => {
  assert.equal(count(migrationSql, "create table public.student_academic_records"), 1);
  assert.equal(count(migrationSql, "create table public.faculty_academic_records"), 1);
  assert.equal(count(migrationSql, "drop constraint if exists human_identities_verification_source_check"), 1);
  assert.equal(count(migrationSql, "add constraint human_identities_verification_source_check"), 1);
  assert.equal(count(migrationSql, "create trigger student_academic_identity_guard"), 1);
  assert.equal(count(migrationSql, "create trigger faculty_academic_identity_guard"), 1);
  assert.equal(count(migrationSql, "create policy student_academic_records_select_own"), 1);
  assert.equal(count(migrationSql, "create policy faculty_academic_records_select_own"), 1);
  assert.equal(count(migrationSql, "alter table public.student_academic_records enable row level security"), 1);
  assert.equal(count(migrationSql, "alter table public.faculty_academic_records enable row level security"), 1);
});

test("migration 0034 declares the synthetic source marker and student/faculty fields", () => {
  assert.ok(migrationSql.includes("'INSTITUTION_PROVIDER','MANUAL_ADMIN','LEGACY_INVITATION','SYNTHETIC_SEED'"),
    "the verification-source constraint must include the explicit synthetic marker");
  assert.ok(migrationSql.includes("academic_track text not null check (academic_track in ("));
  assert.ok(migrationSql.includes("gpa numeric(3,2) not null check (gpa between 0.00 and 4.00)"));
  assert.ok(migrationSql.includes("gpa_scale numeric(2,1) not null default 4.0 check (gpa_scale = 4.0)"));
  assert.ok(migrationSql.includes("specialization text not null"));
  assert.ok(migrationSql.includes("academic_title text not null check (academic_title in ("));
});

test("migration 0034 restricts academic reads to the owning profile", () => {
  assert.ok(migrationSql.includes(
    "create policy student_academic_records_select_own on public.student_academic_records\n" +
    "  for select to authenticated using (profile_id = (select auth.uid()));"));
  assert.ok(migrationSql.includes(
    "create policy faculty_academic_records_select_own on public.faculty_academic_records\n" +
    "  for select to authenticated using (profile_id = (select auth.uid()));"));
  assert.ok(migrationSql.includes("revoke all on public.student_academic_records, public.faculty_academic_records from public, anon, authenticated"));
});

test("university fixture has 20 students, 10 faculty, 10 admins and 20 distinct GPA values", () => {
  assert.deepEqual(validateUniversityFixtures(university), []);
  assert.equal(university.students.length,20);
  assert.equal(university.faculty.length,10);
  assert.equal(university.administrators.length,10);
  assert.equal(new Set(university.students.map((s: any)=>s.gpa)).size,20);
  assert.ok(university.students.every((s: any)=>s.gpa_scale===4.0 && s.gpa>=0 && s.gpa<=4));
  assert.equal(new Set(university.students.map((s: any)=>s.academic_track)).size,7);
});

test("university fixture validation requires at least five distinct approved tracks", () => {
  const invalid = structuredClone(university);
  const keepTracks = new Set([
    "Software Engineering", "Artificial Intelligence",
    "Data Science and Analytics", "Cybersecurity",
  ]);
  for (const student of invalid.students) {
    if (!keepTracks.has(student.academic_track)) student.academic_track = "Software Engineering";
  }
  assert.equal(new Set(invalid.students.map((student: any) => student.academic_track)).size, 4);
  assert.ok(validateUniversityFixtures(invalid).some((error: string) => error.includes("at least five")));
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
  assert.match(sql,/raw_user_meta_data.*synthetic_seed/);
  assert.match(sql,/raw_user_meta_data.*seed_key/);
  assert.ok(sql.includes("private.normalize_auth_phone(a.phone)"),
    "Auth's plus-stripped storage representation must be normalized before comparing the fixture E.164 phone");
  assert.ok(sql.includes("a.phone_confirmed_at is not null"),
    "phone confirmation remains a required seed precondition");
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

test("E.164 accepts 8- and 15-digit international numbers and rejects invalid boundaries", () => {
  assert.equal(isValidE164Phone("+12345678"), true, "minimum 8 digits after plus");
  assert.equal(isValidE164Phone("+123456789012345"), true, "maximum 15 digits after plus");
  for (const invalid of [
    "12345678901",       // missing plus
    "+0123456789",       // leading zero after plus
    "+123-456-7890",     // punctuation
    "+123 4567890",      // whitespace
    "+1234567",          // too short
    "+1234567890123456", // too long
    "+12345abc890",
    "",
    null,
  ]) assert.equal(isValidE164Phone(invalid as any), false, String(invalid));
});

test("Auth phone request and the Auth trigger preserve the same normalized E.164 phone", () => {
  for (const account of [...university.students, ...university.faculty, ...university.administrators]) {
    const req = buildCreatePhoneUserRequest("http://127.0.0.1:54321", "local-key", account, "synthetic-test-password");
    const body = JSON.parse(req.init.body as string);
    assert.equal(body.phone, account.phone);
    assert.equal(body.phone_confirm, true);
  }
  assert.ok(phoneMigrationSql.includes("private.normalize_auth_phone(new.phone)"),
    "the Auth trigger restores GoTrue's stripped leading plus before writing profiles.phone");
  assert.ok(phoneMigrationSql.includes("private.normalize_auth_phone(v_phone_number)"),
    "registration finalization uses the same canonical phone normalizer");
});

test("Auth phone canonicalization accepts both GoTrue storage and application E.164 forms", () => {
  for (const account of [...university.students, ...university.faculty, ...university.administrators]) {
    assert.equal(canonicalAuthPhone(account.phone), account.phone);
    assert.equal(canonicalAuthPhone(account.phone.slice(1)), account.phone);
  }
  for (const invalid of ["", "0123456789", "+0123456789", "+123-456-7890", "1234567", "1234567890123456", null]) {
    assert.equal(canonicalAuthPhone(invalid as any), null, String(invalid));
  }
});

test("Auth provisioning second pass reuses all 40 users whose stored phone omits the plus", async () => {
  const users = [...university.students, ...university.faculty, ...university.administrators].map((account: any) => ({
    id: `auth-${account.seed_key}`,
    phone: account.phone.slice(1),
    email: null,
    user_metadata: { synthetic_seed: true, seed_key: account.seed_key },
  }));
  const result = await provisionUniversityAccounts({
    supabaseUrl: "http://127.0.0.1:54321",
    serviceRoleKey: "local-test-key",
    password: "synthetic-test-password",
    accounts: university,
    fetchImpl: async () => ({ ok: true, json: async () => ({ users }) }) as any,
  });
  assert.deepEqual(result, { created: 0, reused: 40, total: 40 });
});

test("Auth provisioning accepts the provider's plus-stripped create response for all 40 users", async () => {
  let createCalls = 0;
  const result = await provisionUniversityAccounts({
    supabaseUrl: "http://127.0.0.1:54321",
    serviceRoleKey: "local-test-key",
    password: "synthetic-test-password",
    accounts: university,
    fetchImpl: async (url: string, init?: any) => {
      if (url.includes("/admin/users?page=")) return { ok: true, json: async () => ({ users: [] }) } as any;
      const request = JSON.parse(init.body);
      createCalls += 1;
      return {
        ok: true,
        json: async () => ({
          id: `created-${createCalls}`,
          phone: request.phone.slice(1),
          email: null,
          user_metadata: request.user_metadata,
        }),
      } as any;
    },
  });
  assert.equal(createCalls, 40);
  assert.deepEqual(result, { created: 40, reused: 0, total: 40 });
});

test("migration 0035 restores E.164 profile phones without weakening the database constraint", () => {
  assert.ok(phoneMigrationSql.includes("create or replace function private.normalize_auth_phone"));
  assert.ok(phoneMigrationSql.includes("btrim(p_phone) ~ '^[1-9][0-9]{7,14}$'"));
  assert.ok(phoneMigrationSql.includes("'+' || btrim(p_phone)"));
  assert.ok(phoneMigrationSql.includes("private.normalize_auth_phone(new.phone)"));
  assert.ok(phoneMigrationSql.includes("private.normalize_auth_phone(v_phone_number)"));
  assert.doesNotMatch(phoneMigrationSql, /drop constraint if exists profiles_phone_format_check/i);
});

test("Auth phone constraint failures reveal only masked requested/profile phone diagnostics", () => {
  const requested = "+12345678901";
  const persisted = "12345678901";
  const response = JSON.stringify({
    code: "23514",
    message: 'new row for relation "profiles" violates check constraint "profiles_phone_format_check"',
    detail: "Failing row contains (11111111-1111-1111-1111-111111111111, Synthetic Student, null, null, PENDING_VERIFICATION, 2026-11-26, 2026-11-26, " + persisted + ", null).",
  });
  const diagnostic = summarizeAuthCreateFailure(response, requested);
  assert.match(diagnostic, /"constraint":"profiles_phone_format_check"/);
  assert.match(diagnostic, /"leadingPlus":false/);
  assert.match(diagnostic, /"validE164":false/);
  assert.match(diagnostic, /"matchesRequested":false/);
  assert.doesNotMatch(diagnostic, /\+12345678901|12345678901|11111111-1111/);
});

test("local CV evaluation cleanup authenticates metadata DELETE as service_role", () => {
  const cvScript = readFileSync(new URL("../scripts/evaluate-cv-parser-local.mjs", import.meta.url), "utf8");
  const start = cvScript.indexOf("async function cleanup(");
  const end = cvScript.indexOf("\n}\n", start);
  assert.ok(start >= 0 && end > start, "CV cleanup function must exist");
  const cleanup = cvScript.slice(start, end + 3);
  assert.match(cleanup, /method:"DELETE",headers:headers\(service,service,/);
  assert.doesNotMatch(cleanup, /method:"DELETE",headers:headers\(service,null,/);
  assert.match(cleanup, /headers:headers\(service,service,/);
});

test("local phone/password Auth has an SMS transport without enabling public signup", () => {
  const config = readFileSync(new URL("../supabase/config.toml", import.meta.url), "utf8");
  assert.match(config, /^\[auth\]\s*\nenable_signup = false/m);
  assert.match(config, /\[auth\.sms\][\s\S]*?\nenabled = true\s*\nenable_confirmations = true/);
  assert.match(config, /\[auth\.sms\.twilio\][\s\S]*?\nenabled = true\s*\naccount_sid = "AC_LOCAL_TEST_ONLY"\s*\nmessage_service_sid = "MG_LOCAL_TEST_ONLY"\s*\nauth_token = "LOCAL_TEST_ONLY_NOT_A_SECRET"/);
  assert.ok(config.includes("credentials are deliberately fake"),
    "the local provider must never contain real SMS credentials");
  assert.doesNotMatch(config, /\[auth\.sms\][\s\S]*?\nenable_signup\s*=/,
    "use the current auth.sms.enabled provider switch, not the deprecated alias");
});


test("DevOps cohort has its configured future Cloud Day recommendation in the seeded catalogue", () => {
  const cloudDay = opportunities.find((o: any) => o.seed_key === "trn-cloud-day");
  const devops = JSON.parse(readFileSync(new URL("../fixtures/career-cohort-round1.json", import.meta.url), "utf8"))
    .users.find((user: any) => user.code === "07-DEVOPS");
  assert.ok(cloudDay, "Cloud Day fixture must exist");
  assert.equal(cloudDay.title, "Cloud Day (registration opens later)");
  assert.ok(cloudDay.registration_opens_days > 0, "Cloud Day is an upcoming, not immediately registrable, training");
  assert.ok(["DOCKER", "LINUX", "AWS", "CLOUD_BASICS", "DEVOPS_CI_CD"].every((id) =>
    cloudDay.skills.some((skill: any) => skill.skill_id === id)));
  assert.ok(devops.recommendation_titles.includes(cloudDay.title),
    "the configured DevOps cohort expectation must point to a seeded matching catalogue entry");
});

test("career cohort activates its reviewed CV before attempting job applications", () => {
  const integration = readFileSync(new URL("../tests/integration/career-cohort.integration.mjs", import.meta.url), "utf8");
  const activeSelection = integration.indexOf("graduate selects the completed reviewed CV as their active application document");
  const application = integration.indexOf("p_cv_document_id: user.cvId");
  assert.ok(activeSelection >= 0 && application > activeSelection,
    "a graduate must explicitly select a completed CV before passing its ID to apply_for_job");
  assert.match(integration, /method: "PATCH"[\s\S]*?JSON\.stringify\(\{ is_active: true \}\)/);
});
