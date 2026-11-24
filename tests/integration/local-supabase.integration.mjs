import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase integration environment is incomplete");
const host = new URL(base).hostname;
assert.ok(["127.0.0.1", "localhost", "::1"].includes(host), "refusing to run against a non-local Supabase URL");

const demos = JSON.parse(readFileSync(new URL("../../fixtures/demo-profiles.json", import.meta.url), "utf8"));
assert.ok(demos.length >= 4, "four demo graduates are required for career-profile integration coverage");
const [demoA, demoB] = demos;
const demoData = demos.find((item) => item.email === "graduate.data@alumni.test");
const demoCyber = demos.find((item) => item.email === "graduate.cyber@alumni.test");
assert.ok(demoData && demoCyber, "data and cybersecurity demo graduates are required");
let passed = 0;
const pass = (name, condition = true) => {
  assert.equal(Boolean(condition), true, name);
  passed++;
  console.log(`PASS ${name}`);
};
const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: `Bearer ${token}` } : {}),
  ...extra,
});
async function readResponse(res) {
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* response may be binary */ }
  return { status: res.status, ok: res.ok, text, json };
}
async function request(path, init = {}) {
  const res = await fetch(`${base}${path}`, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) });
  return readResponse(res);
}
async function login(email) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password }),
  });
  pass(`Auth password grant: ${email}`, r.status === 200 && Boolean(r.json?.access_token && r.json?.user?.id));
  return { token: r.json.access_token, id: r.json.user.id };
}
const a = await login(demoA.email);
const b = await login(demoB.email);
const dataGraduate = await login(demoData.email);
const cyberGraduate = await login(demoCyber.email);
const encodePath = (p) => p.split("/").map(encodeURIComponent).join("/");
const bucket = "cv-documents";
const objectPath = `${a.id}/ci-${randomUUID()}.pdf`;
const foreignPath = `${a.id}/ci-foreign-${randomUUID()}.pdf`;
const pdf = Buffer.from("%PDF-1.4\n% local Supabase integration test\n1 0 obj<<>>endobj\n%%EOF\n");
let cvId = null;
const injectedSkillRows = [];
const careerPathIds = (response) => response.json?.career_profile?.paths?.map((item) => item.id) ?? [];
const hasCareerPath = (response, id) => careerPathIds(response).includes(id);

async function addTemporaryCareerSkills(graduateId, skillIds) {
  const rows = skillIds.map((skill_id) => ({ graduate_id: graduateId, skill_id, level: 4, source: "MANUAL" }));
  const result = await request("/rest/v1/graduate_skills", {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(rows),
  });
  pass("temporary career-path skills inserted for integration profile " + graduateId,
    result.status === 201 && Array.isArray(result.json) && result.json.length === rows.length);
  if (result.status === 201) injectedSkillRows.push({ graduate_id: graduateId, skill_ids: skillIds });
}

async function removeObject(token, path) {
  return request(`/storage/v1/object/${bucket}`, {
    method: "DELETE",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ prefixes: [path] }),
  });
}
try {
  // Profile ownership through PostgREST.
  const ownProfile = await request(`/rest/v1/profiles?select=id,email&id=eq.${a.id}`, { headers: headers(a.token) });
  pass("graduate can read own profile", ownProfile.status === 200 && ownProfile.json?.length === 1 && ownProfile.json[0].email === demoA.email);
  const otherProfile = await request(`/rest/v1/profiles?select=id,email&id=eq.${b.id}`, { headers: headers(a.token) });
  pass("graduate cannot read another profile", otherProfile.status === 200 && otherProfile.json?.length === 0);

  // The Edge Function is exercised over the real local HTTP gateway, with JWT verification enabled.
  const getFunction = await request("/functions/v1/recommend", {
    method: "GET", headers: headers(a.token),
  });
  pass("recommend endpoint rejects non-POST methods", getFunction.status === 405);
  const noAuth = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(null, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint rejects missing JWT", noAuth.status === 401);
  const invalidAuth = await request("/functions/v1/recommend", {
    method: "POST", headers: headers("invalid.jwt.token", { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint rejects invalid JWT", invalidAuth.status === 401);

  const first = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint computes recommendations for user A", first.status === 200 &&
    first.json?.source === "computed" && Array.isArray(first.json?.items) &&
    first.json?.ai_mode === "deterministic" && typeof first.json?.model_version === "string" &&
    typeof first.json?.disclaimer === "string" && Array.isArray(first.json?.career_profile?.paths));
  pass("career intelligence returns Sara's inferred Data Analytics path", hasCareerPath(first, "DATA_ANALYTICS"));
  pass("career path score and evidence are included in the API response",
    Number.isInteger(first.json?.career_profile?.paths?.[0]?.score) &&
    first.json.career_profile.paths[0].score >= 0 && first.json.career_profile.paths[0].score <= 100 &&
    Array.isArray(first.json.career_profile.paths[0].skill_evidence));
  const second = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint serves user A cache on second request", second.status === 200 &&
    second.json?.source === "cache" && Array.isArray(second.json?.items));
  pass("career profile is recalculated from the caller's own skills on cache hits", hasCareerPath(second, "DATA_ANALYTICS"));
  const forced = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: JSON.stringify({ force: true }),
  });
  pass("recommend force=true recomputes user A cache", forced.status === 200 && forced.json?.source === "computed");
  const otherUser = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint independently computes for user B", otherUser.status === 200 &&
    otherUser.json?.source === "computed" && Array.isArray(otherUser.json?.items));
  pass("Ahmed's own career profile includes Mobile", hasCareerPath(otherUser, "MOBILE"));

  const dataResult = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(dataGraduate.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("Data Science graduate profile is recognized by the live Edge Function",
    dataResult.status === 200 && hasCareerPath(dataResult, "DATA_SCIENCE") && hasCareerPath(dataResult, "DATA_ANALYTICS"));
  const cyberResult = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(cyberGraduate.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("Cybersecurity graduate profile is recognized by the live Edge Function",
    cyberResult.status === 200 && hasCareerPath(cyberResult, "CYBERSECURITY"));

  // Inject isolated test-only skills to exercise Frontend + Data and Backend + Mobile profiles end to end.
  await addTemporaryCareerSkills(a.id, ["HTML_CSS", "JAVASCRIPT", "REACT"]);
  const frontendMulti = await request("/functions/v1/recommend", {
    method: "POST",
    headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ force: true }),
  });
  pass("live Edge Function infers Frontend for a frontend-skilled graduate", hasCareerPath(frontendMulti, "FRONTEND"));
  pass("live Edge Function preserves multiple paths (Frontend + Data) for one graduate",
    hasCareerPath(frontendMulti, "FRONTEND") && hasCareerPath(frontendMulti, "DATA_ANALYTICS"));

  await addTemporaryCareerSkills(b.id, ["NODE_JS", "REST_API", "POSTGRESQL"]);
  const backendMulti = await request("/functions/v1/recommend", {
    method: "POST",
    headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ force: true }),
  });
  pass("live Edge Function infers Backend from Node.js + REST + PostgreSQL",
    hasCareerPath(backendMulti, "BACKEND"));
  pass("live Edge Function preserves Backend + Mobile as concurrent paths",
    hasCareerPath(backendMulti, "BACKEND") && hasCareerPath(backendMulti, "MOBILE"));

  // Read own recommendation rows through the authenticated PostgREST client; RLS must prevent cross-user leakage.
  const recA = await request("/rest/v1/recommendations?select=graduate_id", { headers: headers(a.token) });
  pass("recommendations query for user A exposes only A rows", recA.status === 200 &&
    Array.isArray(recA.json) && recA.json.every((x) => x.graduate_id === a.id));
  const recB = await request("/rest/v1/recommendations?select=graduate_id", { headers: headers(b.token) });
  pass("recommendations query for user B exposes only B rows", recB.status === 200 &&
    Array.isArray(recB.json) && recB.json.every((x) => x.graduate_id === b.id));

  // Storage API upload as A, then prove that B cannot read, upload into, or delete A's object.
  const uploadA = await request(`/storage/v1/object/${bucket}/${encodePath(objectPath)}`, {
    method: "POST",
    headers: headers(a.token, { "Content-Type": "application/pdf", "x-upsert": "false" }),
    body: pdf,
  });
  pass("Storage API allows A to upload into A's folder", uploadA.status === 200 || uploadA.status === 201);

  // CV metadata row is tied to the caller's uid and Storage path.
  const cvInsert = await request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(a.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({ graduate_id: a.id, storage_path: objectPath, file_type: "pdf", size_bytes: pdf.length }),
  });
  pass("A can create CV metadata for A's uploaded object", cvInsert.status === 201 && Array.isArray(cvInsert.json) && cvInsert.json.length === 1);
  cvId = cvInsert.json?.[0]?.id ?? null;

  const bMetadata = await request(`/rest/v1/cv_documents?select=id,storage_path&storage_path=eq.${encodeURIComponent(objectPath)}`, {
    headers: headers(b.token),
  });
  pass("B cannot read A's CV metadata through RLS", bMetadata.status === 200 && Array.isArray(bMetadata.json) && bMetadata.json.length === 0);

  const bReadObject = await request(`/storage/v1/object/${bucket}/${encodePath(objectPath)}`, { headers: headers(b.token) });
  pass("B cannot read A's private CV object", !bReadObject.ok);

  const bUploadForeign = await request(`/storage/v1/object/${bucket}/${encodePath(foreignPath)}`, {
    method: "POST",
    headers: headers(b.token, { "Content-Type": "application/pdf", "x-upsert": "false" }),
    body: pdf,
  });
  pass("B cannot upload into A's Storage folder", !bUploadForeign.ok);

  const bDelete = await removeObject(b.token, objectPath);
  const stillThere = await request(`/storage/v1/object/${bucket}/${encodePath(objectPath)}`, { headers: headers(a.token) });
  pass("B cannot delete A's Storage object", stillThere.status === 200);

  const ownRead = await request(`/storage/v1/object/${bucket}/${encodePath(objectPath)}`, { headers: headers(a.token) });
  pass("A can read A's private CV object", ownRead.status === 200);

  const aDelete = await removeObject(a.token, objectPath);
  const afterDelete = await request(`/storage/v1/object/${bucket}/${encodePath(objectPath)}`, { headers: headers(a.token) });
  pass("Storage API lets A delete own object and it disappears", aDelete.ok && !afterDelete.ok);

  const aMetadataDelete = cvId
    ? await request(`/rest/v1/cv_documents?id=eq.${cvId}`, { method: "DELETE", headers: headers(a.token) })
    : { ok: false, status: 0 };
  pass("A can delete own CV metadata row", aMetadataDelete.ok);
} finally {
  // Remove only temporary skill rows inserted for these career-path integration cases.
  for (const injected of injectedSkillRows) {
    const cleanup = await request(
      "/rest/v1/graduate_skills?graduate_id=eq." + injected.graduate_id +
        "&skill_id=in.(" + injected.skill_ids.join(",") + ")",
      { method: "DELETE", headers: headers(service) },
    );
    pass("temporary career-path skills cleaned up for " + injected.graduate_id, cleanup.ok);
  }
  // Cleanup uses the local service role through the Storage/PostgREST APIs, never direct SQL on storage.objects.
  await removeObject(service, objectPath).catch(() => {});
  await removeObject(service, foreignPath).catch(() => {});
  if (cvId) await request(`/rest/v1/cv_documents?id=eq.${cvId}`, {
    method: "DELETE", headers: headers(service),
  }).catch(() => {});
}

console.log(`LOCAL HTTP INTEGRATION PASSED: ${passed} checks`);
