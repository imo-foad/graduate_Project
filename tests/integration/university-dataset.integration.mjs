import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { assertLocalSupabaseApiUrl, canonicalAuthPhone } from "../../scripts/provision-university-demo-users.mjs";
import { assertLocalUniversitySeedTargets } from "../../scripts/seed-university-demo.mjs";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "synthetic university integration environment is incomplete");
assertLocalSupabaseApiUrl(base);
assertLocalUniversitySeedTargets(base, process.env.DB_URL ?? "", process.env);

const fixture = JSON.parse(readFileSync(new URL("../../fixtures/university-accounts.json", import.meta.url), "utf8"));
const students = fixture.students;
const faculty = fixture.faculty;
const administrators = fixture.administrators;
assert.equal(students.length, 20, "fixture must contain 20 students");
assert.equal(faculty.length, 10, "fixture must contain 10 faculty");
assert.equal(administrators.length, 10, "fixture must contain 10 administrators");

const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
const serviceHeaders = (extra = {}) => ({
  apikey: service,
  Authorization: "Bearer " + service,
  ...extra,
});
async function request(path, init = {}, serviceRole = false) {
  const response = await fetch(base + path, {
    ...init,
    headers: serviceRole ? serviceHeaders(init.headers ?? {}) : headers(init.token ?? null, init.headers ?? {}),
    signal: init.signal ?? AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* keep raw body for diagnostics */ }
  return { status: response.status, ok: response.ok, text, json };
}
let passed = 0;
const pass = (name, condition) => {
  assert.equal(Boolean(condition), true, name);
  passed += 1;
  console.log("PASS " + name);
};
const q = (path, token) => request(path, { token });
const serviceGet = (path) => request(path, {}, true);
const encode = (v) => encodeURIComponent(String(v));

async function login(account) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ phone: account.phone, password }),
  });
  assert.equal(r.status, 200, "phone/password login failed for " + account.seed_key + ": " + r.status + " " + r.text);
  assert.ok(r.json?.access_token && r.json?.user?.id, "Auth token/user missing for " + account.seed_key);
  return { token: r.json.access_token, id: r.json.user.id, user: r.json.user };
}

try {
  // Independent fixture validation: the committed data must exceed the five-track minimum.
  const tracks = new Set(students.map((s) => s.academic_track));
  const gpas = students.map((s) => s.gpa);
  const phones = [...students, ...faculty, ...administrators].map((x) => x.phone);
  const refs = [...students, ...faculty].map((x) => x.institution_ref);
  pass("20 student GPAs are distinct and within the explicit 4.0 scale",
    new Set(gpas).size === 20 && students.every((s) => s.gpa_scale === 4.0 &&
      Number.isFinite(s.gpa) && s.gpa >= 0 && s.gpa <= 4 &&
      Math.round(s.gpa * 100) === s.gpa * 100));
  pass("seven documented academic tracks satisfy the five-track minimum",
    tracks.size === 7 && tracks.size >= 5 &&
      [...tracks].every((track) => fixture.meta.approved_tracks.includes(track)));
  pass("all 40 phone numbers and 30 student/faculty institutional references are unique",
    new Set(phones).size === 40 && new Set(refs).size === 30);
  pass("fixture contains no real email, National ID or password fields",
    [...students, ...faculty, ...administrators].every((x) =>
      !("email" in x) && !("national_id" in x) && !("nationalId" in x) && !("password" in x)));
  pass("only STUDENT/FACULTY have human identity types; admins are private grants",
    students.every((x) => x.identity_type === "STUDENT") &&
      faculty.every((x) => x.identity_type === "FACULTY") &&
      administrators.every((x) => !("identity_type" in x) && x.admin_role === "PLATFORM_ADMIN"));

  // Host allow-list negative cases must reject before any request is sent.
  pass("supported localhost API URL is accepted", assertLocalSupabaseApiUrl(base) === base);
  for (const raw of [
    "https://127.0.0.1:54321",
    "http://127.0.0.1.evil.example:54321",
    "http://127.0.0.1:54321@evil.example",
    "http://10.0.0.12:54321",
    "http://localhost:54322",
  ]) {
    let rejected = false;
    try { assertLocalSupabaseApiUrl(raw); } catch { rejected = true; }
    pass("non-local/deceptive API target rejected: " + raw, rejected);
  }
  let hostedDbRejected = false;
  try {
    assertLocalUniversitySeedTargets(base, "postgresql://postgres:password@db.example.supabase.co:5432/postgres", process.env);
  } catch { hostedDbRejected = true; }
  pass("hosted database URL is rejected before provisioning or SQL writes", hostedDbRejected);

  // Look up the provisioned IDs through the server-only credential; no secret is returned to clients.
  const accounts = [
    ...students.map((account) => ({ account, kind: "STUDENT" })),
    ...faculty.map((account) => ({ account, kind: "FACULTY" })),
    ...administrators.map((account) => ({ account, kind: "ADMIN" })),
  ];
  const ids = new Map();
  for (const { account, kind } of accounts) {
    const profile = await serviceGet(
      "/rest/v1/profiles?select=id,phone,email,account_status&phone=eq." + encode(account.phone),
    );
    assert.equal(profile.status, 200, "profile lookup failed: " + account.seed_key + " " + profile.text);
    assert.equal(profile.json?.length, 1, "missing/duplicate profile: " + account.seed_key);
    const row = profile.json[0];
    assert.equal(row.phone, account.phone, "Auth phone must be persisted unchanged to profiles.phone");
    assert.equal(row.phone, account.phone, "profiles.phone must retain the canonical E.164 representation");
    assert.equal(row.email, null, "synthetic phone account must not have an email");
    assert.equal(row.account_status, "ACTIVE", "synthetic account must be active after local seed");
    ids.set(account.seed_key, row.id);

    const auth = await request("/auth/v1/admin/users/" + encode(row.id), {}, true);
    assert.equal(auth.status, 200, "Auth Admin lookup failed: " + account.seed_key);
    const authUser = auth.json?.user ?? auth.json;
    const metadata = authUser.user_metadata ?? authUser.raw_user_meta_data ?? {};
    pass(account.seed_key + " is phone-only, confirmed and explicitly synthetic",
      canonicalAuthPhone(authUser.phone) === account.phone && !authUser.email &&
        Boolean(authUser.phone_confirmed_at) && metadata.synthetic_seed === true &&
        metadata.seed_key === account.seed_key);

    const identities = await serviceGet(
      "/rest/v1/human_identities?select=identity_type,institution_ref,status,verification_source,attributes&profile_id=eq." + encode(row.id),
    );
    assert.equal(identities.status, 200, "identity lookup failed: " + account.seed_key);
    if (kind === "STUDENT" || kind === "FACULTY") {
      pass(account.seed_key + " has exactly one matching VERIFIED SYNTHETIC_SEED identity",
        identities.json?.length === 1 &&
          identities.json[0].identity_type === kind &&
          identities.json[0].institution_ref === account.institution_ref &&
          identities.json[0].status === "VERIFIED" &&
          identities.json[0].verification_source === "SYNTHETIC_SEED" &&
          identities.json[0].attributes?.demo_verification === "SIMULATED_LOCAL_ONLY");
    } else {
      pass(account.seed_key + " has no ADMIN or other human identity",
        identities.json?.length === 0);
    }

    const graduates = await serviceGet(
      "/rest/v1/graduate_profiles?select=profile_id&profile_id=eq." + encode(row.id),
    );
    assert.equal(graduates.status, 200, "graduate profile lookup failed: " + account.seed_key);
    pass(account.seed_key + " is not silently granted a graduate profile", graduates.json?.length === 0);
  }

  // Verify the two student identities and one faculty identity through real phone/password Auth.
  const studentA = await login(students[0]);
  const studentB = await login(students[1]);
  const facultyA = await login(faculty[0]);
  const adminA = await login(administrators[0]);
  pass("student, faculty and synthetic admin accounts authenticate with phone + password",
    studentA.id === ids.get(students[0].seed_key) &&
      studentB.id === ids.get(students[1].seed_key) &&
      facultyA.id === ids.get(faculty[0].seed_key) &&
      adminA.id === ids.get(administrators[0].seed_key));

  const ownStudent = await q(
    "/rest/v1/student_academic_records?select=profile_id,institution_ref,gpa,gpa_scale,academic_track&profile_id=eq." + encode(studentA.id),
    studentA.token,
  );
  pass("student can read their own private academic record",
    ownStudent.status === 200 && ownStudent.json?.length === 1 &&
      ownStudent.json[0].institution_ref === students[0].institution_ref &&
      Number(ownStudent.json[0].gpa) === students[0].gpa &&
      Number(ownStudent.json[0].gpa_scale) === 4);
  const otherStudent = await q(
    "/rest/v1/student_academic_records?select=profile_id&profile_id=eq." + encode(studentB.id),
    studentA.token,
  );
  pass("student cannot read another student's academic record",
    otherStudent.status === 200 && otherStudent.json?.length === 0);
  const studentFaculty = await q(
    "/rest/v1/faculty_academic_records?select=profile_id&profile_id=eq." + encode(facultyA.id),
    studentA.token,
  );
  pass("student cannot read a faculty academic record",
    studentFaculty.status === 200 && studentFaculty.json?.length === 0);

  const ownFaculty = await q(
    "/rest/v1/faculty_academic_records?select=profile_id,institution_ref,department,specialization,academic_title&profile_id=eq." + encode(facultyA.id),
    facultyA.token,
  );
  pass("faculty can read their own typed faculty record",
    ownFaculty.status === 200 && ownFaculty.json?.length === 1 &&
      ownFaculty.json[0].institution_ref === faculty[0].institution_ref &&
      ownFaculty.json[0].department === faculty[0].department &&
      ownFaculty.json[0].specialization === faculty[0].specialization &&
      ownFaculty.json[0].academic_title === faculty[0].academic_title);
  const facultyStudent = await q(
    "/rest/v1/student_academic_records?select=profile_id&profile_id=eq." + encode(studentA.id),
    facultyA.token,
  );
  pass("faculty identity does not grant access to student-only records",
    facultyStudent.status === 200 && facultyStudent.json?.length === 0);

  const studentAdmin = await request("/rest/v1/rpc/assert_platform_admin", {
    method: "POST", token: studentA.token, headers: { "Content-Type": "application/json" }, body: "{}",
  });
  pass("ordinary student cannot pass the platform-admin guard",
    studentAdmin.status === 403 && /ADMIN_REQUIRED/.test(studentAdmin.text));
  const facultyAdmin = await request("/rest/v1/rpc/assert_platform_admin", {
    method: "POST", token: facultyA.token, headers: { "Content-Type": "application/json" }, body: "{}",
  });
  pass("ordinary faculty cannot pass the platform-admin guard",
    facultyAdmin.status === 403 && /ADMIN_REQUIRED/.test(facultyAdmin.text));
  const selfGrant = await request("/rest/v1/rpc/set_platform_admin_access", {
    method: "POST", token: studentA.token, headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ p_user_id: studentA.id, p_is_active: true, p_reason: "self privilege escalation QA" }),
  });
  pass("student cannot grant themselves platform-admin membership",
    selfGrant.status === 403 && /ADMIN_REQUIRED/.test(selfGrant.text));
  const adminGuard = await request("/rest/v1/rpc/assert_platform_admin", {
    method: "POST", token: adminA.token, headers: { "Content-Type": "application/json" }, body: "{}",
  });
  pass("a legitimate local synthetic admin passes the private membership guard",
    adminGuard.status === 200 && adminGuard.json === true);

  const studentWrite = await request("/rest/v1/student_academic_records", {
    method: "POST", token: studentA.token,
    headers: { "Content-Type": "application/json", Prefer: "return=representation" },
    body: JSON.stringify({
      profile_id: studentA.id,
      institution_ref: "SYNTH-STU-9999",
      department: "Computer Science",
      major: "Software Engineering",
      academic_track: "Software Engineering",
      academic_level: 1,
      gpa: 4.00,
      gpa_scale: 4.0,
    }),
  });
  pass("authenticated student cannot write or forge academic records",
    studentWrite.status === 401 || studentWrite.status === 403);

  const idWrite = await request("/rest/v1/human_identities", {
    method: "POST", token: studentA.token,
    headers: { "Content-Type": "application/json", Prefer: "return=representation" },
    body: JSON.stringify({
      profile_id: studentA.id,
      identity_type: "FACULTY",
      institution_ref: "SYNTH-FAC-9999",
      status: "VERIFIED",
      verification_source: "SYNTHETIC_SEED",
      attributes: { synthetic_seed: true },
    }),
  });
  pass("authenticated student cannot self-assign or forge another human identity",
    idWrite.status === 401 || idWrite.status === 403);

  const graduateDemos = [
    "graduate.demo@alumni.test",
    "graduate.android@alumni.test",
    "graduate.data@alumni.test",
    "graduate.cyber@alumni.test",
  ];
  let graduatesPreserved = true;
  for (const email of graduateDemos) {
    const profile = await serviceGet("/rest/v1/profiles?select=id,email&email=eq." + encode(email));
    if (profile.status !== 200 || profile.json?.length !== 1) { graduatesPreserved = false; continue; }
    const id = profile.json[0].id;
    const gp = await serviceGet("/rest/v1/graduate_profiles?select=profile_id&profile_id=eq." + encode(id));
    if (gp.status !== 200 || gp.json?.length !== 1) graduatesPreserved = false;
  }
  pass("all four original graduate demo profiles remain intact", graduatesPreserved);

  // Service-role inspection proves administrators are private grants, not human identity rows.
  const allSyntheticIdentities = await serviceGet(
    "/rest/v1/human_identities?select=profile_id,identity_type,verification_source&verification_source=eq.SYNTHETIC_SEED",
  );
  pass("synthetic seed verification rows contain only 20 STUDENT and 10 FACULTY identities",
    allSyntheticIdentities.status === 200 && allSyntheticIdentities.json?.length >= 30 &&
      allSyntheticIdentities.json.filter((x) => x.identity_type === "STUDENT").length === 20 &&
      allSyntheticIdentities.json.filter((x) => x.identity_type === "FACULTY").length === 10 &&
      allSyntheticIdentities.json.every((x) => x.identity_type !== "ADMIN"));

  console.log("UNIVERSITY DATASET HTTP INTEGRATION PASSED: " + passed + " checks");
} catch (error) {
  console.error("UNIVERSITY DATASET HTTP INTEGRATION FAILED:", error?.stack ?? error);
  throw error;
}
