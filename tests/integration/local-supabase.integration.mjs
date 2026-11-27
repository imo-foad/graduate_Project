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
const pass = (name, condition = true, details = undefined) => {
  const message = details === undefined
    ? name
    : `${name}; diagnostics=${JSON.stringify(details)}`;
  assert.equal(Boolean(condition), true, message);
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
let socialPostId = null;
let socialSecondPostId = null;
let socialCommentId = null;
const availabilityOpportunityIds = [];
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

  // Capture the exact input to the recommendation engine so an empty result cannot masquerade as a cache failure.
  const rawCatalogue = await request(
    "/rest/v1/opportunities?select=id,seed_key,type,status,deadline,end_at,company_id,company_verification_status&order=seed_key.asc",
    { headers: headers(service) },
  );
  const candidateProjection = await request("/rest/v1/rpc/get_recommendation_candidates", {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_graduate_id: a.id }),
  });
  const rawRows = Array.isArray(rawCatalogue.json) ? rawCatalogue.json : [];
  const projectedRows = Array.isArray(candidateProjection.json?.opportunities)
    ? candidateProjection.json.opportunities
    : [];
  console.info("recommendation candidate diagnostics", JSON.stringify({
    raw_status: rawCatalogue.status,
    raw_count: rawRows.length,
    raw_active_scoped: rawRows.filter((row) => row.status === "ACTIVE" && ["JOB", "INTERNSHIP", "TRAINING"].includes(row.type)).length,
    raw_company_owned: rawRows.filter((row) => row.company_id !== null).length,
    raw_examples: rawRows.slice(0, 5).map(({ seed_key, type, status, company_id, company_verification_status }) =>
      ({ seed_key, type, status, company_id, company_verification_status })),
    candidate_status: candidateProjection.status,
    candidate_error: candidateProjection.json?.message ?? candidateProjection.json?.error ?? null,
    candidate_count: projectedRows.length,
    candidate_types: projectedRows.reduce((out, row) => {
      out[row.type] = (out[row.type] ?? 0) + 1;
      return out;
    }, {}),
    candidate_examples: projectedRows.slice(0, 5).map(({ id, type, title, eligibility_failures }) =>
      ({ id, type, title, eligibility_failures })),
  }));
  pass("recommendation SQL candidate projection returns active, rankable listings",
    candidateProjection.status === 200 && Array.isArray(candidateProjection.json?.opportunities) &&
      candidateProjection.json.opportunities.length > 0,
    { status: candidateProjection.status, diagnostics: {
      raw_open_scoped: rawRows.filter((row) => row.status === "ACTIVE" && ["JOB", "INTERNSHIP", "TRAINING"].includes(row.type)).length,
      candidate_count: projectedRows.length,
      candidate_types: projectedRows.reduce((out, row) => { out[row.type] = (out[row.type] ?? 0) + 1; return out; }, {}),
    }, body: candidateProjection.json ?? candidateProjection.text });
  const first = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("recommend endpoint computes recommendations for user A", first.status === 200 &&
    first.json?.source === "computed" && Array.isArray(first.json?.items) && first.json.items.length > 0 &&
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
    second.json?.source === "cache" && Array.isArray(second.json?.items) && second.json.items.length > 0, {
      status: second.status,
      source: second.json?.source ?? null,
      error: second.json?.error ?? null,
      code: second.json?.code ?? null,
      items_count: Array.isArray(second.json?.items) ? second.json.items.length : null,
      body: second.json ?? second.text,
    });
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

  // Availability (issue #16): a full training without a waitlist must never be recommended, a full training
  // with a waitlist must be labelled WAITLIST_ONLY, and a future registration window must be labelled UPCOMING.
  const oneHourAgo = new Date(Date.now() - 3_600_000).toISOString();
  const inOneDay = new Date(Date.now() + 86_400_000).toISOString();
  const inOneWeek = new Date(Date.now() + 7 * 86_400_000).toISOString();
  const availabilityEvents = [
    { key: "full", type: "TRAINING", body: { title: "CI full training (no waitlist)", capacity: 1, registered_count: 1, waitlist_enabled: false, registration_opens_at: oneHourAgo } },
    { key: "waitlist", type: "TRAINING", body: { title: "CI waitlist training", capacity: 1, registered_count: 1, waitlist_enabled: true, registration_opens_at: oneHourAgo } },
    { key: "upcoming", type: "TRAINING", body: { title: "CI upcoming training registration", capacity: 5, registered_count: 0, waitlist_enabled: false, registration_opens_at: inOneDay } },
    { key: "job-full", type: "JOB", body: { title: "CI job at capacity", capacity: 1, registered_count: 1, waitlist_enabled: false, registration_opens_at: oneHourAgo } },
    { key: "internship-full", type: "INTERNSHIP", body: { title: "CI internship at capacity", capacity: 1, registered_count: 1, waitlist_enabled: false, registration_opens_at: oneHourAgo } },
    { key: "job-future", type: "JOB", body: { title: "CI job with future registration timestamp", capacity: 5, registered_count: 0, waitlist_enabled: false, registration_opens_at: inOneDay } },
    { key: "internship-future", type: "INTERNSHIP", body: { title: "CI internship with future registration timestamp", capacity: 5, registered_count: 0, waitlist_enabled: false, registration_opens_at: inOneDay } },
  ];
  for (const event of availabilityEvents) {
    const created = await request("/rest/v1/opportunities", {
      method: "POST",
      headers: headers(service, { "Content-Type": "application/json", Prefer: "return=representation" }),
      body: JSON.stringify({
        seed_key: `ci-availability-${event.key}-${randomUUID()}`,
        type: event.type,
        title: event.body.title,
        description: "Temporary training created by the local HTTP integration test.",
        location: "Cairo",
        attendance_mode: "ONSITE",
        status: "ACTIVE",
        deadline: inOneWeek,
        start_at: inOneWeek,
        end_at: inOneWeek,
        registration_opens_at: event.body.registration_opens_at,
        capacity: event.body.capacity,
        registered_count: event.body.registered_count,
        waitlist_enabled: event.body.waitlist_enabled,
        target_fields: ["Computer Science"],
      }),
    });
    pass(`availability fixture ${event.key} created`, created.status === 201 && Boolean(created.json?.[0]?.id));
    event.id = created.json?.[0]?.id;
    if (event.id) availabilityOpportunityIds.push(event.id);
  }
  const availability = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: JSON.stringify({ force: true }),
  });
  const availabilityItems = Array.isArray(availability.json?.items) ? availability.json.items : [];
  const itemFor = (key) => availabilityItems.find((item) => item.opportunity_id === availabilityEvents.find((e) => e.key === key)?.id);
  pass("recommendations exclude a full training without a waitlist", availability.status === 200 && !itemFor("full"));
  pass("recommendations label a full training with a waitlist as WAITLIST_ONLY",
    itemFor("waitlist")?.availability_status === "WAITLIST_ONLY");
  pass("recommendations keep a future registration window as UPCOMING",
    itemFor("upcoming")?.availability_status === "UPCOMING");
  // JOB/INTERNSHIP use applications: Training-only capacity and registration-window fields must not
  // exclude them or make the API report FULL/UPCOMING.
  for (const key of ["job-full", "internship-full", "job-future", "internship-future"]) {
    pass(`recommendations keep ${key} despite Training-only fields`,
      Boolean(itemFor(key)) && itemFor(key)?.availability_status === null,
      { item: itemFor(key) ?? null });
  }
  const cachedAvailability = await request("/functions/v1/recommend", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
  });
  const cachedItems = Array.isArray(cachedAvailability.json?.items) ? cachedAvailability.json.items : [];
  const cachedItemFor = (key) => cachedItems.find((item) =>
    item.opportunity_id === availabilityEvents.find((e) => e.key === key)?.id);
  pass("cached recommendations apply the same availability filter",
    cachedAvailability.status === 200 && cachedAvailability.json?.source === "cache" &&
    !cachedItemFor("full") &&
    cachedItemFor("waitlist")?.availability_status === "WAITLIST_ONLY" &&
    cachedItemFor("upcoming")?.availability_status === "UPCOMING");
  for (const key of ["job-full", "internship-full", "job-future", "internship-future"]) {
    pass(`cached recommendations keep ${key} with null availability`,
      Boolean(cachedItemFor(key)) && cachedItemFor(key)?.availability_status === null,
      { item: cachedItemFor(key) ?? null });
  }

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

  // Cancelled product scope (#14 Scholarship, #15 Competition): the whole surface must be gone.
  const cancelledCatalogue = await request(
    "/rest/v1/opportunities?select=id,type&type=in.(SCHOLARSHIP,COMPETITION)",
    { headers: headers(a.token) },
  );
  pass("cancelled opportunity types are absent from catalogue discovery",
    cancelledCatalogue.status === 200 && Array.isArray(cancelledCatalogue.json) && cancelledCatalogue.json.length === 0);

  for (const [name, path] of [
    ["apply_for_scholarship", "/rest/v1/rpc/apply_for_scholarship"],
    ["withdraw_scholarship_application", "/rest/v1/rpc/withdraw_scholarship_application"],
    ["apply_for_competition", "/rest/v1/rpc/apply_for_competition"],
    ["withdraw_competition_application", "/rest/v1/rpc/withdraw_competition_application"],
  ]) {
    const denied = await request(path, {
      method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
    });
    pass(`cancelled RPC ${name} is not executable by a client`, denied.status === 403 || denied.status === 404);
  }

  for (const [name, path] of [
    ["scholarship_applications", "/rest/v1/scholarship_applications?select=id&limit=1"],
    ["competition_applications", "/rest/v1/competition_applications?select=id&limit=1"],
  ]) {
    const denied = await request(path, { headers: headers(a.token) });
    pass(`cancelled table ${name} is not readable by a client`, denied.status === 403 || denied.status === 404);
  }

  for (const name of ["submit-scholarship", "deliver-scholarship", "get-scholarship-review-cv", "scholarship-provider-callback"]) {
    const gone = await request(`/functions/v1/${name}`, {
      method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
    });
    pass(`cancelled Edge Function ${name} is not deployed`, gone.status === 404);
  }

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

  // Metadata deletion is routed through an owner-scoped RPC that also enqueues Storage cleanup.
  // Direct PostgREST DELETE is revoked so a failure cannot bypass the cleanup ledger.
  const directDelete = cvId
    ? await request(`/rest/v1/cv_documents?id=eq.${cvId}`, { method: "DELETE", headers: headers(a.token) })
    : { ok: false, status: 0 };
  pass("direct CV metadata DELETE is rejected for clients", !directDelete.ok,
    { status: directDelete.status, body: directDelete.json ?? directDelete.text });
  const aMetadataDelete = cvId
    ? await request("/rest/v1/rpc/delete_cv_document", {
      method: "POST",
      headers: headers(a.token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ p_cv_document_id: cvId }),
    })
    : { ok: false, status: 0 };
  pass("A can delete own CV metadata through the owner-scoped RPC",
    aMetadataDelete.status === 200 && aMetadataDelete.json?.deleted === true, { status: aMetadataDelete.status });
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

  // Remove the temporary availability fixtures (recommendations cascade with the opportunity).
  for (const opportunityId of availabilityOpportunityIds) {
    await request("/rest/v1/recommendations?opportunity_id=eq." + opportunityId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => {});
    await request("/rest/v1/opportunities?id=eq." + opportunityId, {
      method: "DELETE", headers: headers(service),
    }).catch(() => {});
  }

  // Cleanup uses the local service role through the Storage/PostgREST APIs, never direct SQL on storage.objects.
  await removeObject(service, objectPath).catch(() => {});
  await removeObject(service, foreignPath).catch(() => {});
  if (cvId) await request(`/rest/v1/cv_documents?id=eq.${cvId}`, {
    method: "DELETE", headers: headers(service),
  }).catch(() => {});
}

console.log(`LOCAL HTTP INTEGRATION PASSED: ${passed} checks`);
