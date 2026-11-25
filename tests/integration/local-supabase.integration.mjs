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
let scholarshipApplicationId = null;
let scholarshipOpportunityId = null;
let competitionApplicationId = null;
let competitionOpportunityId = null;
let socialPostId = null;
let socialSecondPostId = null;
let socialCommentId = null;
const injectedSkillRows = [];
const careerPathIds = (response) => response.json?.career_profile?.paths?.map((item) => item.id) ?? [];
const hasCareerPath = (response, id) => careerPathIds(response).includes(id);

async function addTemporaryCareerSkills(token, graduateId, skillIds) {
  const rows = skillIds.map((skill_id) => ({ graduate_id: graduateId, skill_id, level: 4, source: "MANUAL" }));
  const result = await request("/rest/v1/graduate_skills", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(rows),
  });
  pass("temporary career-path skills inserted for integration profile " + graduateId,
    result.status === 201 && Array.isArray(result.json) && result.json.length === rows.length);
  if (result.status === 201) injectedSkillRows.push({ token, graduate_id: graduateId, skill_ids: skillIds });
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
  // A freshly started local Edge Function can briefly restart after the CLI's readiness probe.
  // Retry the same GET for a bounded interval; success still requires the real handler's HTTP 405.
  const MAX_FUNCTION_METHOD_RETRIES = 10;
  let getFunction = { status: 0, json: null, text: "request not attempted" };
  for (let attempt = 0; attempt < MAX_FUNCTION_METHOD_RETRIES; attempt++) {
    try {
      getFunction = await request("/functions/v1/recommend", {
        method: "GET", headers: headers(a.token),
      });
    } catch (error) {
      getFunction = { status: 0, json: null, text: String(error) };
    }
    if (getFunction.status === 405) break;
    if (attempt < MAX_FUNCTION_METHOD_RETRIES - 1) {
      console.warn(`Retrying recommend method guard after HTTP ${getFunction.status} (attempt ${attempt + 1}/${MAX_FUNCTION_METHOD_RETRIES})`);
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  if (getFunction.status !== 405) {
    console.error("recommend method guard diagnostics:", {
      status: getFunction.status,
      body: (getFunction.json ?? getFunction.text ?? "").toString().slice(0, 1000),
    });
  }
  pass("recommend endpoint rejects non-POST methods", getFunction.status === 405,
    { status: getFunction.status, body: getFunction.json ?? getFunction.text });
  const noAuth = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(null, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint rejects missing JWT", noAuth.status === 401,
    { status: noAuth.status, body: noAuth.json ?? noAuth.text });
  const invalidAuth = await request("/functions/v1/recommend", {
    method: "POST", headers: headers("invalid.jwt.token", { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint rejects invalid JWT", invalidAuth.status === 401,
    { status: invalidAuth.status, body: invalidAuth.json ?? invalidAuth.text });

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
  await addTemporaryCareerSkills(a.token, a.id, ["HTML_CSS", "JAVASCRIPT", "REACT"]);
  const frontendMulti = await request("/functions/v1/recommend", {
    method: "POST",
    headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ force: true }),
  });
  pass("live Edge Function infers Frontend for a frontend-skilled graduate", hasCareerPath(frontendMulti, "FRONTEND"));
  pass("live Edge Function preserves multiple paths (Frontend + Data) for one graduate",
    hasCareerPath(frontendMulti, "FRONTEND") && hasCareerPath(frontendMulti, "DATA_ANALYTICS"));

  await addTemporaryCareerSkills(b.token, b.id, ["NODE_JS", "REST_API", "POSTGRESQL"]);
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

  // Full graduate scholarship journey over the authenticated PostgREST RPCs.
  const scholarshipCatalog = await request(
    "/rest/v1/opportunities?select=id,type&seed_key=eq.schol-masters-cs",
    { headers: headers(a.token) },
  );
  pass("seed scholarship is visible in the catalogue",
    scholarshipCatalog.status === 200 && scholarshipCatalog.json?.length === 1 &&
    scholarshipCatalog.json[0]?.type === "SCHOLARSHIP");
  scholarshipOpportunityId = scholarshipCatalog.json?.[0]?.id ?? null;
  assert.ok(scholarshipOpportunityId, "seed SCHOLARSHIP opportunity is required");
  assert.ok(cvId, "caller-owned CV metadata row is required");

  const noAuthScholarship = await request("/functions/v1/submit-scholarship", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_opportunity_id: scholarshipOpportunityId }),
  });
  pass("scholarship submit endpoint rejects missing JWT", noAuthScholarship.status === 401);

  const scholarshipSubmit = await request("/functions/v1/submit-scholarship", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      p_opportunity_id: scholarshipOpportunityId,
      p_cv_document_id: cvId,
      p_personal_statement: "I am applying to continue postgraduate study in computing.",
      p_application_data: { study_area: "Computer Science", motivation: "Research" },
    }),
  });
  pass("graduate submits sample scholarship; platform labels it internal-only",
    scholarshipSubmit.status === 200 &&
    scholarshipSubmit.json?.status === "INTERNAL_ONLY" &&
    scholarshipSubmit.json?.delivery_status === "NOT_REQUIRED" &&
    scholarshipSubmit.json?.external_submission === false);
  scholarshipApplicationId = scholarshipSubmit.json?.application_id ?? null;
  assert.ok(scholarshipApplicationId, "scholarship application id is required");

  const scholarshipOwn = await request(
    "/rest/v1/scholarship_applications?select=id,status,personal_statement,application_data&id=eq." + scholarshipApplicationId,
    { headers: headers(a.token) },
  );
  pass("graduate reads own scholarship form and status",
    scholarshipOwn.status === 200 && scholarshipOwn.json?.length === 1 &&
    scholarshipOwn.json[0]?.status === "INTERNAL_ONLY" &&
    scholarshipOwn.json[0]?.application_data?.study_area === "Computer Science" &&
    scholarshipOwn.json[0]?.personal_statement?.startsWith("I am applying"));

  const scholarshipDuplicate = await request("/rest/v1/rpc/apply_for_scholarship", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_opportunity_id: scholarshipOpportunityId }),
  });
  pass("duplicate scholarship submission returns ALREADY_APPLIED",
    scholarshipDuplicate.status === 409 && scholarshipDuplicate.json?.message === "ALREADY_APPLIED");

  const peerScholarship = await request(
    "/rest/v1/scholarship_applications?select=id&id=eq." + scholarshipApplicationId,
    { headers: headers(b.token) },
  );
  pass("peer graduate cannot read scholarship submission",
    peerScholarship.status === 200 && Array.isArray(peerScholarship.json) && peerScholarship.json.length === 0);

  const scholarshipHistory = await request(
    "/rest/v1/scholarship_application_status_history?select=old_status,new_status,source_type&scholarship_application_id=eq." + scholarshipApplicationId,
    { headers: headers(a.token) },
  );
  pass("scholarship status history is readable by its owner",
    scholarshipHistory.status === 200 && scholarshipHistory.json?.length === 1 &&
    scholarshipHistory.json[0]?.new_status === "INTERNAL_ONLY" &&
    scholarshipHistory.json[0]?.source_type === "GRADUATE_ACTION");

  const scholarshipWithdraw = await request("/rest/v1/rpc/withdraw_scholarship_application", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_application_id: scholarshipApplicationId }),
  });
  pass("graduate withdraws own scholarship application",
    scholarshipWithdraw.status === 200 && scholarshipWithdraw.json?.status === "WITHDRAWN");

  const scholarshipWithdrawAgain = await request("/rest/v1/rpc/withdraw_scholarship_application", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_application_id: scholarshipApplicationId }),
  });
  pass("repeated scholarship withdrawal is rejected",
    scholarshipWithdrawAgain.status === 422 && scholarshipWithdrawAgain.json?.message === "CANNOT_WITHDRAW_SCHOLARSHIP_APPLICATION");

  const scholarshipReapply = await request("/rest/v1/rpc/apply_for_scholarship", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_opportunity_id: scholarshipOpportunityId }),
  });
  pass("withdrawn scholarship application cannot be submitted again",
    scholarshipReapply.status === 409 && scholarshipReapply.json?.message === "ALREADY_APPLIED");

  const scholarshipNotifications = await request(
    "/rest/v1/notifications?select=type,related_entity_id&type=in.(SCHOLARSHIP_APPLICATION_INTERNAL_ONLY,SCHOLARSHIP_APPLICATION_WITHDRAWN)",
    { headers: headers(a.token) },
  );
  pass("scholarship submit and withdraw notifications are created",
    scholarshipNotifications.status === 200 &&
    scholarshipNotifications.json?.some((n) => n.type === "SCHOLARSHIP_APPLICATION_INTERNAL_ONLY" && n.related_entity_id === scholarshipApplicationId) &&
    scholarshipNotifications.json?.some((n) => n.type === "SCHOLARSHIP_APPLICATION_WITHDRAWN" && n.related_entity_id === scholarshipApplicationId));

  // Competition entry is intentionally separate from event registration.
  const competitionCatalog = await request(
    "/rest/v1/opportunities?select=id,type&seed_key=eq.comp-hackathon",
    { headers: headers(a.token) },
  );
  pass("seed competition is visible in the catalogue",
    competitionCatalog.status === 200 && competitionCatalog.json?.length === 1 &&
    competitionCatalog.json[0]?.type === "COMPETITION");
  competitionOpportunityId = competitionCatalog.json?.[0]?.id ?? null;
  assert.ok(competitionOpportunityId, "seed COMPETITION opportunity is required");

  const competitionSubmit = await request("/rest/v1/rpc/apply_for_competition", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      p_opportunity_id: competitionOpportunityId,
      p_cv_document_id: cvId,
      p_personal_statement: "I am submitting my software prototype for review.",
      p_submission_data: { project_title: "Campus Assist", project_url: "https://example.test/project" },
    }),
  });
  pass("graduate submits a competition entry over HTTP",
    competitionSubmit.status === 200 && competitionSubmit.json?.status === "SUBMITTED" &&
    competitionSubmit.json?.opportunity_id === competitionOpportunityId && competitionSubmit.json?.graduate_id === a.id);
  competitionApplicationId = competitionSubmit.json?.id ?? null;
  assert.ok(competitionApplicationId, "competition application id is required");

  const competitionOwn = await request(
    "/rest/v1/competition_applications?select=id,status,personal_statement,submission_data&id=eq." + competitionApplicationId,
    { headers: headers(a.token) },
  );
  pass("graduate reads own competition entry",
    competitionOwn.status === 200 && competitionOwn.json?.length === 1 &&
    competitionOwn.json[0]?.status === "SUBMITTED" &&
    competitionOwn.json[0]?.submission_data?.project_title === "Campus Assist");

  const competitionDuplicate = await request("/rest/v1/rpc/apply_for_competition", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_opportunity_id: competitionOpportunityId }),
  });
  pass("duplicate competition entry returns ALREADY_APPLIED",
    competitionDuplicate.status === 409 && competitionDuplicate.json?.message === "ALREADY_APPLIED");

  const peerCompetition = await request(
    "/rest/v1/competition_applications?select=id&id=eq." + competitionApplicationId,
    { headers: headers(b.token) },
  );
  pass("another graduate cannot read competition entry",
    peerCompetition.status === 200 && Array.isArray(peerCompetition.json) && peerCompetition.json.length === 0);

  const competitionHistory = await request(
    "/rest/v1/competition_application_status_history?select=old_status,new_status,source_type&competition_application_id=eq." + competitionApplicationId,
    { headers: headers(a.token) },
  );
  pass("competition history is readable by its owner",
    competitionHistory.status === 200 && competitionHistory.json?.length === 1 &&
    competitionHistory.json[0]?.new_status === "SUBMITTED");

  const competitionWithdraw = await request("/rest/v1/rpc/withdraw_competition_application", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_application_id: competitionApplicationId }),
  });
  pass("graduate withdraws own competition entry",
    competitionWithdraw.status === 200 && competitionWithdraw.json?.status === "WITHDRAWN");

  const competitionWithdrawAgain = await request("/rest/v1/rpc/withdraw_competition_application", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_application_id: competitionApplicationId }),
  });
  pass("repeated competition withdrawal is rejected",
    competitionWithdrawAgain.status === 422 && competitionWithdrawAgain.json?.message === "CANNOT_WITHDRAW_COMPETITION_APPLICATION");

  const competitionReapply = await request("/rest/v1/rpc/apply_for_competition", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_opportunity_id: competitionOpportunityId }),
  });
  pass("withdrawn competition entry cannot be submitted again",
    competitionReapply.status === 409 && competitionReapply.json?.message === "ALREADY_APPLIED");

  const competitionNotifications = await request(
    "/rest/v1/notifications?select=type,related_entity_id&type=in.(COMPETITION_APPLICATION_SUBMITTED,COMPETITION_APPLICATION_WITHDRAWN)",
    { headers: headers(a.token) },
  );
  pass("competition submit and withdraw notifications are created",
    competitionNotifications.status === 200 &&
    competitionNotifications.json?.some((n) => n.type === "COMPETITION_APPLICATION_SUBMITTED" && n.related_entity_id === competitionApplicationId) &&
    competitionNotifications.json?.some((n) => n.type === "COMPETITION_APPLICATION_WITHDRAWN" && n.related_entity_id === competitionApplicationId));

  // Social Feed: access is available only through the narrow authenticated RPC projection.
  const socialCreate = await request("/rest/v1/rpc/create_social_post", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_content: "  Alumni Connect community update  " }),
  });
  pass("graduate creates a Social Feed post", socialCreate.status === 200 &&
    socialCreate.json?.content === "Alumni Connect community update" && socialCreate.json?.author_id === a.id);
  socialPostId = socialCreate.json?.id ?? null;
  assert.ok(socialPostId, "Social Feed post id is required");

  const socialOwnIdentity = await request("/rest/v1/profiles?select=full_name&id=eq." + a.id, { headers: headers(a.token) });
  pass("post author can read own display name for comparison", socialOwnIdentity.status === 200 && socialOwnIdentity.json?.length === 1);
  const socialFeed = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_before_created_at: null, p_before_id: null, p_limit: 20 }),
  });
  const socialItem = socialFeed.json?.find((item) => item.id === socialPostId);
  pass("another graduate sees post with display-only identity", socialFeed.status === 200 &&
    !Object.hasOwn(socialItem ?? {}, "author_id") && socialItem?.author_name === socialOwnIdentity.json?.[0]?.full_name &&
    Object.hasOwn(socialItem ?? {}, "author_avatar_url") && !("email" in (socialItem ?? {})) && !("phone" in (socialItem ?? {})));

  const socialSecondCreate = await request("/rest/v1/rpc/create_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_content: "Second post for cursor pagination" }),
  });
  pass("second graduate creates separate feed post", socialSecondCreate.status === 200 &&
    socialSecondCreate.json?.author_id === b.id && socialSecondCreate.json?.content === "Second post for cursor pagination");
  socialSecondPostId = socialSecondCreate.json?.id ?? null;
  assert.ok(socialSecondPostId, "second Social Feed post id is required");

  const socialPageOne = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_before_created_at: null, p_before_id: null, p_limit: 1 }),
  });
  const socialCursorItem = socialPageOne.json?.[0];
  const socialPageTwo = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_before_created_at: socialCursorItem?.created_at, p_before_id: socialCursorItem?.id, p_limit: 1 }),
  });
  pass("Social Feed keyset pagination reaches next distinct item", socialPageOne.status === 200 &&
    socialPageOne.json?.length === 1 && socialPageTwo.status === 200 && socialPageTwo.json?.length === 1 &&
    socialPageTwo.json[0]?.id !== socialCursorItem?.id);

  const socialRawTable = await request("/rest/v1/social_posts?select=id", { headers: headers(a.token) });
  pass("graduate cannot bypass Social Feed RPCs through raw posts table", !socialRawTable.ok);

  const socialComment = await request("/rest/v1/rpc/add_social_comment", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId, p_content: "  Great to reconnect  " }),
  });
  pass("graduate adds a comment to another active graduate post", socialComment.status === 200 &&
    socialComment.json?.post_id === socialPostId && socialComment.json?.content === "Great to reconnect");
  socialCommentId = socialComment.json?.id ?? null;
  assert.ok(socialCommentId, "Social Feed comment id is required");

  const socialComments = await request("/rest/v1/rpc/get_social_post_comments", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId, p_before_created_at: null, p_before_id: null, p_limit: 20 }),
  });
  pass("post owner reads comments with display-only author fields", socialComments.status === 200 &&
    socialComments.json?.some((item) => item.id === socialCommentId && !Object.hasOwn(item, "author_id") &&
      item.author_name === demoB.full_name && item.content === "Great to reconnect" &&
      !("email" in item) && !("phone" in item)));

  const socialCommentUpdate = await request("/rest/v1/rpc/update_social_comment", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_comment_id: socialCommentId, p_content: "Edited comment" }),
  });
  pass("comment author edits own comment", socialCommentUpdate.status === 200 && socialCommentUpdate.json?.content === "Edited comment");
  const socialForeignCommentEdit = await request("/rest/v1/rpc/update_social_comment", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_comment_id: socialCommentId, p_content: "Attempted foreign edit" }),
  });
  pass("another graduate cannot edit someone else's comment", socialForeignCommentEdit.status === 404 &&
    socialForeignCommentEdit.json?.message === "SOCIAL_COMMENT_NOT_FOUND");

  const socialCommentDelete = await request("/rest/v1/rpc/delete_social_comment", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_comment_id: socialCommentId }),
  });
  pass("comment author deletes own comment", socialCommentDelete.status === 200 && socialCommentDelete.json === true);
  socialCommentId = null;
  const socialCommentAgain = await request("/rest/v1/rpc/add_social_comment", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId, p_content: "Comment to verify post cascade" }),
  });
  pass("new comment can be added after deleting previous comment", socialCommentAgain.status === 200);
  socialCommentId = socialCommentAgain.json?.id ?? null;

  const socialLike = await request("/rest/v1/rpc/like_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("graduate likes a Social Feed post", socialLike.status === 200 && socialLike.json === true);
  const socialDuplicateLike = await request("/rest/v1/rpc/like_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("duplicate like is rejected", socialDuplicateLike.status === 409 && socialDuplicateLike.json?.message === "ALREADY_LIKED");
  const socialLikedFeed = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_limit: 20 }),
  });
  pass("feed exposes aggregate count and caller liked_by_me flag", socialLikedFeed.status === 200 &&
    socialLikedFeed.json?.some((item) => item.id === socialPostId && item.likes_count === 1 && item.liked_by_me === true));
  const socialUnlike = await request("/rest/v1/rpc/unlike_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("graduate removes own like", socialUnlike.status === 200 && socialUnlike.json === true);
  const socialUnlikeAgain = await request("/rest/v1/rpc/unlike_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("unlike without existing like is rejected", socialUnlikeAgain.status === 404 && socialUnlikeAgain.json?.message === "NOT_LIKED");

  const socialForeignPostEdit = await request("/rest/v1/rpc/update_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId, p_content: "Foreign edit" }),
  });
  pass("another graduate cannot edit a post", socialForeignPostEdit.status === 404 &&
    socialForeignPostEdit.json?.message === "SOCIAL_POST_NOT_FOUND");
  const socialForeignPostDelete = await request("/rest/v1/rpc/delete_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("another graduate cannot delete a post", socialForeignPostDelete.status === 404 &&
    socialForeignPostDelete.json?.message === "SOCIAL_POST_NOT_FOUND");

  const socialPostUpdate = await request("/rest/v1/rpc/update_social_post", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId, p_content: "Updated alumni network announcement" }),
  });
  pass("post author edits own post", socialPostUpdate.status === 200 &&
    socialPostUpdate.json?.content === "Updated alumni network announcement");
  const socialInvalidPost = await request("/rest/v1/rpc/create_social_post", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_content: "   " }),
  });
  pass("blank Social Feed post is rejected", socialInvalidPost.status === 422 && socialInvalidPost.json?.message === "INVALID_INPUT");
  const socialInvalidPage = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_limit: 0 }),
  });
  pass("invalid Social Feed page size is rejected", socialInvalidPage.status === 422 && socialInvalidPage.json?.message === "INVALID_INPUT");

  const socialDelete = await request("/rest/v1/rpc/delete_social_post", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialPostId }),
  });
  pass("post author deletes own post", socialDelete.status === 200 && socialDelete.json === true);
  socialPostId = null;
  const socialAfterDelete = await request("/rest/v1/rpc/get_social_feed", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_limit: 50 }),
  });
  pass("deleted post and its comments/likes disappear from feed", socialAfterDelete.status === 200 &&
    !socialAfterDelete.json?.some((item) => item.content === "Updated alumni network announcement"));
  const socialSecondDelete = await request("/rest/v1/rpc/delete_social_post", {
    method: "POST", headers: headers(b.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_post_id: socialSecondPostId }),
  });
  pass("second post author can delete own post", socialSecondDelete.status === 200 && socialSecondDelete.json === true);
  socialSecondPostId = null;


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
      { method: "DELETE", headers: headers(injected.token) },
    );
    pass("temporary career-path skills cleaned up for " + injected.graduate_id, cleanup.ok);
  }
  // Remove Social Feed test posts that remain if an earlier assertion aborts the journey.
  for (const [postId, token] of [[socialPostId, a.token], [socialSecondPostId, b.token]]) {
    if (!postId) continue;
    const cleanup = await request("/rest/v1/rpc/delete_social_post", {
      method: "POST", headers: headers(token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ p_post_id: postId }),
    }).catch(() => ({ ok: false, status: 0 }));
    pass("remaining Social Feed test post cleanup", cleanup.status === 200 || cleanup.status === 404);
  }

  // Remove data created by the synthetic competition workflow before reruns.
  const competitionCleanup = [];
  if (competitionApplicationId) {
    competitionCleanup.push(await request("/rest/v1/competition_applications?id=eq." + competitionApplicationId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
    competitionCleanup.push(await request("/rest/v1/notifications?related_entity_id=eq." + competitionApplicationId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
  }
  if (competitionOpportunityId) {
    competitionCleanup.push(await request("/rest/v1/recommendation_interactions?graduate_id=eq." + a.id +
      "&opportunity_id=eq." + competitionOpportunityId + "&interaction_type=eq.APPLY", {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
  }
  if (competitionApplicationId) pass("competition test side effects cleaned up", competitionCleanup.length === 3 && competitionCleanup.every((r) => r.ok));

  // Remove data generated by this synthetic scholarship test so that reruns are deterministic.
  const scholarshipCleanup = [];
  if (scholarshipApplicationId) {
    scholarshipCleanup.push(await request("/rest/v1/scholarship_applications?id=eq." + scholarshipApplicationId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
    scholarshipCleanup.push(await request("/rest/v1/notifications?related_entity_id=eq." + scholarshipApplicationId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
  }
  if (scholarshipOpportunityId) {
    scholarshipCleanup.push(await request("/rest/v1/recommendation_interactions?graduate_id=eq." + a.id +
      "&opportunity_id=eq." + scholarshipOpportunityId + "&interaction_type=eq.APPLY", {
      method: "DELETE", headers: headers(service),
    }).catch(() => ({ ok: false })));
  }
  if (scholarshipApplicationId) pass("scholarship test rows cleaned up", scholarshipCleanup.length === 3 && scholarshipCleanup.every((r) => r.ok));

  // Cleanup uses the local service role through the Storage/PostgREST APIs, never direct SQL on storage.objects.
  await removeObject(service, objectPath).catch(() => {});
  await removeObject(service, foreignPath).catch(() => {});
  if (cvId) await request(`/rest/v1/cv_documents?id=eq.${cvId}`, {
    method: "DELETE", headers: headers(service),
  }).catch(() => {});
}

console.log(`LOCAL HTTP INTEGRATION PASSED: ${passed} checks`);
