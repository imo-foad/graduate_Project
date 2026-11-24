import assert from "node:assert/strict";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "career cohort integration environment is incomplete");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(base).hostname),
  "refusing to run the career cohort against a non-local Supabase URL");

const round = process.argv[2] ?? "round1";
assert.ok(["round1", "round2"].includes(round), "pass round1 or round2");
const cohort = JSON.parse(readFileSync(new URL("../../fixtures/career-cohort-" + round + ".json", import.meta.url), "utf8"));
const skillCatalogue = JSON.parse(readFileSync(new URL("../../fixtures/skills.json", import.meta.url), "utf8"));
const skillNames = new Map(skillCatalogue.map((item) => [item.id, item.name]));
const runId = randomUUID().replace(/-/g, "").slice(0, 12);
assert.equal(cohort.users.length, 10, "each cohort round must contain exactly ten graduates");

const CATEGORY_WEIGHTS = {
  profile_auth: 8,
  cv_storage_privacy: 12,
  extraction_accuracy: 18,
  suggestion_review: 14,
  structured_records: 14,
  career_classification: 16,
  recommendations: 8,
  graduate_workflows: 5,
  insights_feedback: 5,
};
assert.equal(Object.values(CATEGORY_WEIGHTS).reduce((sum, value) => sum + value, 0), 100);

const users = cohort.users.map((fixture) => ({
  ...fixture,
  email: "ci10-" + round + "-" + fixture.code.toLowerCase() + "-" + runId + "@alumni.test",
  checks: [],
  authId: null,
  token: null,
  cvId: null,
  storagePath: null,
  cvBytes: null,
  parseBody: null,
  skillRows: [],
  structuredRows: [],
  recommendationItems: [],
}));

let cleanupFailures = [];
function record(user, category, name, condition, details = undefined) {
  const passed = Boolean(condition);
  user.checks.push({ category, name, passed, ...(passed ? {} : { details: details ?? null }) });
  console.log((passed ? "PASS" : "FAIL") + " [" + user.code + "] " + name);
  if (!passed && details !== undefined) console.error("DIAGNOSTIC [" + user.code + "] " + name + ": " + JSON.stringify(details));
}
function headers(token, extra = {}) {
  return {
    apikey: anon,
    ...(token ? { Authorization: "Bearer " + token } : {}),
    ...extra,
  };
}
async function request(path, init = {}) {
  try {
    const response = await fetch(base + path, {
      ...init,
      signal: init.signal ?? AbortSignal.timeout(60_000),
    });
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* Keep non-JSON payload for diagnostics. */ }
    return { status: response.status, ok: response.ok, text, json };
  } catch (error) {
    return { status: 0, ok: false, text: String(error), json: null };
  }
}
const jsonHeaders = (token) => headers(token, { "Content-Type": "application/json" });
const post = (path, token, body) => request(path, {
  method: "POST", headers: jsonHeaders(token), body: JSON.stringify(body),
});
const getById = (table, select, id, token) =>
  request("/rest/v1/" + table + "?select=" + encodeURIComponent(select) + "&id=eq." + encodeURIComponent(id), {
    headers: headers(token),
  });
function encodePath(path) {
  return path.split("/").map((part) => encodeURIComponent(part)).join("/");
}
function escapePdfLiteral(value) {
  return value.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
}
function buildPdf(text) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const textCommands = lines.map((line, index) =>
    (index === 0 ? "" : "T*\n") + "(" + escapePdfLiteral(line) + ") Tj"
  ).join("\n");
  const stream = ["BT", "/F1 11 Tf", "14 TL", "45 750 Td", textCommands, "ET"].join("\n");
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length " + Buffer.byteLength(stream, "latin1") + " >>\nstream\n" + stream + "\nendstream\nendobj\n",
  ];
  let output = "%PDF-1.4\n% Ten-graduate career cohort fixture\n";
  const offsets = [0];
  for (const object of objects) {
    offsets.push(Buffer.byteLength(output, "latin1"));
    output += object;
  }
  const xref = Buffer.byteLength(output, "latin1");
  output += "xref\n0 6\n0000000000 65535 f \n";
  for (let i = 1; i < offsets.length; i++) {
    output += offsets[i].toString().padStart(10, "0") + " 00000 n \n";
  }
  output += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + xref + "\n%%EOF\n";
  return Buffer.from(output, "latin1");
}
function buildCv(user) {
  const terms = user.skills.map((id) => {
    const name = skillNames.get(id);
    if (!name) throw new Error(user.code + ": skill " + id + " is not in fixtures/skills.json");
    return name;
  });
  const rejectedTerm = skillNames.get(user.reject_skill_id);
  if (!rejectedTerm) throw new Error(user.code + ": rejected skill " + user.reject_skill_id + " is not in catalogue");
  const lines = [
    "CURRICULUM VITAE - " + user.name,
    "Career interest: " + user.track,
    "SKILLS",
    "Core tools and technologies: " + terms.join(", "),
    "Additional skill exposure for review: " + rejectedTerm,
    "WORK EXPERIENCE",
    user.experience.title + " | " + user.experience.company,
    user.experience.date_range,
    user.experience.description,
    "CERTIFICATIONS",
    user.certification.title + " | " + user.certification.issuer + " | " + user.certification.year,
    "COURSES",
    user.course.title + " | " + user.course.provider + " | " + user.course.year + " | " + user.course.duration,
  ];
  return buildPdf(lines.join("\n"));
}
function userProfilePayload(user) {
  return {
    college: "Faculty of Computers and Information",
    department: user.department,
    major: user.major,
    graduation_year: 2025,
    degree: "Bachelor",
    employment_status: "SEEKING",
    location: user.city,
    career_interests: user.interest,
    work_preferences: { work_mode: user.work_mode, preferred_cities: [user.city] },
  };
}
async function createUser(user) {
  const created = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: jsonHeaders(service),
    body: JSON.stringify({
      email: user.email,
      password,
      email_confirm: true,
      user_metadata: { full_name: user.name },
    }),
  });
  const id = created.json?.user?.id ?? created.json?.id ?? null;
  user.authId = id;
  record(user, "profile_auth", "synthetic Auth account is created", [200, 201].includes(created.status) && Boolean(id),
    { status: created.status, body: created.json ?? created.text });
  if (!id) return;
  const login = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: jsonHeaders(null),
    body: JSON.stringify({ email: user.email, password }),
  });
  user.token = login.json?.access_token ?? null;
  record(user, "profile_auth", "graduate can sign in and receives a JWT",
    login.status === 200 && Boolean(user.token) && login.json?.user?.id === id,
    { status: login.status, body: login.json ?? login.text });
  if (!user.token) return;

  const updated = await request("/rest/v1/graduate_profiles?profile_id=eq." + id, {
    method: "PATCH",
    headers: headers(user.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify(userProfilePayload(user)),
  });
  record(user, "profile_auth", "graduate profile is saved with the intended track and work preferences",
    [200, 204].includes(updated.status) && (updated.status === 204 || updated.json?.length === 1),
    { status: updated.status, body: updated.json ?? updated.text });
  const ownProfile = await request("/rest/v1/graduate_profiles?select=profile_id,major,career_interests,work_preferences&profile_id=eq." + id, {
    headers: headers(user.token),
  });
  record(user, "profile_auth", "graduate can read their own profile",
    ownProfile.status === 200 && ownProfile.json?.length === 1 &&
    ownProfile.json[0].major === user.major &&
    ownProfile.json[0].career_interests?.[0] === user.interest[0],
    { status: ownProfile.status, body: ownProfile.json ?? ownProfile.text });
}
async function primeRecommendations(user) {
  if (!user.token) {
    record(user, "recommendations", "empty baseline recommendation snapshot can be computed", false);
    return;
  }
  const baseline = await post("/functions/v1/recommend", user.token, {});
  user.baselineRecommendation = baseline;
  record(user, "recommendations", "new graduate starts with an explicit empty career profile before CV review",
    baseline.status === 200 && baseline.json?.source === "computed" &&
    Array.isArray(baseline.json?.career_profile?.paths) &&
    baseline.json.career_profile.paths.length === 0,
    { status: baseline.status, source: baseline.json?.source,
      careerProfile: baseline.json?.career_profile ?? baseline.json ?? baseline.text });
}
async function uploadAndParse(user) {
  if (!user.token || !user.authId) {
    record(user, "cv_storage_privacy", "CV upload prerequisites are available", false);
    record(user, "extraction_accuracy", "CV parser can be executed", false);
    return;
  }
  user.cvBytes = buildCv(user);
  user.storagePath = user.authId + "/career-cohort/" + round + "-" + user.code + "-" + runId + ".pdf";
  const upload = await request("/storage/v1/object/cv-documents/" + encodePath(user.storagePath), {
    method: "POST",
    headers: headers(user.token, { "Content-Type": "application/pdf", "x-upsert": "false" }),
    body: user.cvBytes,
  });
  record(user, "cv_storage_privacy", "unique CV PDF uploads to the graduate's private folder",
    upload.status === 200 || upload.status === 201, { status: upload.status, body: upload.json ?? upload.text });

  const metadata = await request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(user.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({
      graduate_id: user.authId,
      storage_path: user.storagePath,
      file_type: "pdf",
      size_bytes: user.cvBytes.length,
    }),
  });
  user.cvId = metadata.json?.[0]?.id ?? null;
  record(user, "cv_storage_privacy", "CV metadata is registered for the authenticated owner",
    metadata.status === 201 && Boolean(user.cvId),
    { status: metadata.status, body: metadata.json ?? metadata.text });
  const ownDocument = user.cvId ? await getById("cv_documents", "id,graduate_id,file_type,size_bytes,parse_status", user.cvId, user.token) : null;
  record(user, "cv_storage_privacy", "graduate can read their own CV metadata",
    ownDocument?.status === 200 && ownDocument.json?.length === 1 &&
    ownDocument.json[0].graduate_id === user.authId &&
    ownDocument.json[0].file_type === "pdf" && ownDocument.json[0].size_bytes === user.cvBytes.length,
    { status: ownDocument?.status, body: ownDocument?.json ?? ownDocument?.text });
  const ownFile = await request("/storage/v1/object/cv-documents/" + encodePath(user.storagePath), {
    headers: headers(user.token),
  });
  record(user, "cv_storage_privacy", "graduate can download the original bytes of their own private CV",
    ownFile.status === 200 && ownFile.text.startsWith("%PDF-"),
    { status: ownFile.status, header: ownFile.text.slice(0, 12) });

  if (!user.cvId) {
    record(user, "extraction_accuracy", "CV parser completes and returns DONE", false);
    record(user, "extraction_accuracy", "CV parser extracts every expected skill and no unexpected skill", false);
    record(user, "extraction_accuracy", "CV parser extracts experience, certification and course", false);
    record(user, "extraction_accuracy", "all CV suggestions remain pending until graduate review", false);
    return;
  }
  const parsed = await post("/functions/v1/parse-cv", user.token, { cv_document_id: user.cvId });
  user.parseBody = parsed.json;
  record(user, "extraction_accuracy", "CV parser completes the unique PDF and returns DONE",
    parsed.status === 200 && parsed.json?.status === "DONE" && parsed.json?.confirmation_required === true,
    { status: parsed.status, body: parsed.json ?? parsed.text });

  const completedDocument = await getById("cv_documents", "id,parse_status,error_message,parsed_at", user.cvId, user.token);
  record(user, "extraction_accuracy", "CV document lifecycle is DONE with no processing error",
    completedDocument.status === 200 && completedDocument.json?.[0]?.parse_status === "DONE" &&
    completedDocument.json?.[0]?.error_message === null && Boolean(completedDocument.json?.[0]?.parsed_at),
    { status: completedDocument.status, body: completedDocument.json ?? completedDocument.text });
  const suggestions = await request("/rest/v1/cv_suggestions?select=id,kind,payload,status,cv_document_id&cv_document_id=eq." + user.cvId, {
    headers: headers(user.token),
  });
  user.skillRows = (suggestions.json ?? []).filter((row) => row.kind === "SKILL");
  user.structuredRows = (suggestions.json ?? []).filter((row) => row.kind !== "SKILL");
  const expectedSkillIds = [...user.skills, user.reject_skill_id].sort();
  const actualSkillIds = user.skillRows.map((row) => row.payload?.skill_id).sort();
  const exactSkills = expectedSkillIds.length === actualSkillIds.length &&
    expectedSkillIds.every((id, index) => id === actualSkillIds[index]);
  record(user, "extraction_accuracy", "CV parser extracts the exact expected skill set without omissions or extras",
    suggestions.status === 200 && exactSkills && new Set(actualSkillIds).size === actualSkillIds.length,
    { expectedSkillIds, actualSkillIds, status: suggestions.status });
  const counts = parsed.json?.suggestion_counts ?? {};
  const experienceRows = user.structuredRows.filter((row) => row.kind === "EXPERIENCE");
  const certificationRows = user.structuredRows.filter((row) => row.kind === "CERTIFICATION");
  const courseRows = user.structuredRows.filter((row) => row.kind === "COURSE");
  record(user, "extraction_accuracy", "CV parser extracts one experience, one certificate and one course",
    counts.experience === 1 && counts.certifications === 1 && counts.courses === 1 &&
    experienceRows.length === 1 && certificationRows.length === 1 && courseRows.length === 1,
    { counts, structuredKinds: user.structuredRows.map((row) => row.kind) });
  record(user, "extraction_accuracy", "all skill and structured suggestions are PENDING before review",
    suggestions.status === 200 && suggestions.json?.length === user.skills.length + 4 &&
    suggestions.json.every((row) => row.status === "PENDING") &&
    suggestions.json.every((row) => row.cv_document_id === user.cvId),
    { status: suggestions.status, count: suggestions.json?.length, expected: user.skills.length + 4,
      statuses: (suggestions.json ?? []).map((row) => row.status) });

  const savedSkillsBeforeReview = await request("/rest/v1/graduate_skills?select=skill_id,source&source=eq.CV_CONFIRMED", {
    headers: headers(user.token),
  });
  record(user, "suggestion_review", "no CV skill becomes confirmed before an explicit review",
    savedSkillsBeforeReview.status === 200 && savedSkillsBeforeReview.json?.length === 0,
    { status: savedSkillsBeforeReview.status, body: savedSkillsBeforeReview.json ?? savedSkillsBeforeReview.text });

  const levels = user.skill_levels ?? {};
  const decisions = (suggestions.json ?? []).map((row) => {
    if (row.kind === "SKILL") {
      const id = row.payload?.skill_id;
      if (id === user.reject_skill_id) return { id: row.id, status: "REJECTED" };
      return { id: row.id, status: "CONFIRMED", payload: { ...row.payload, level: levels[id] ?? 4 } };
    }
    return { id: row.id, status: "CONFIRMED" };
  });
  const review = await post("/rest/v1/rpc/review_cv_suggestions", user.token, { p_decisions: decisions });
  const expectedConfirmed = user.skills.length + 3;
  record(user, "suggestion_review", "graduate can confirm all valid CV records and reject one selected skill",
    review.status === 200 && review.json?.confirmed === expectedConfirmed && review.json?.rejected === 1,
    { status: review.status, body: review.json ?? review.text, expectedConfirmed });
  const updatedSuggestions = await request("/rest/v1/cv_suggestions?select=id,kind,payload,status&cv_document_id=eq." + user.cvId, {
    headers: headers(user.token),
  });
  const statusesCorrect = (updatedSuggestions.json ?? []).filter((row) =>
    row.kind === "SKILL" && row.payload?.skill_id === user.reject_skill_id
  ).every((row) => row.status === "REJECTED") &&
    (updatedSuggestions.json ?? []).filter((row) =>
      row.kind === "SKILL" && row.payload?.skill_id !== user.reject_skill_id
    ).every((row) => row.status === "CONFIRMED") &&
    (updatedSuggestions.json ?? []).filter((row) => row.kind !== "SKILL")
      .every((row) => row.status === "CONFIRMED");
  record(user, "suggestion_review", "review decisions persist with exact CONFIRMED and REJECTED statuses",
    updatedSuggestions.status === 200 && statusesCorrect,
    { status: updatedSuggestions.status, statuses: (updatedSuggestions.json ?? []).map((row) => ({
      kind: row.kind, skill_id: row.payload?.skill_id, status: row.status,
    })) });

  const confirmed = await request("/rest/v1/graduate_skills?select=skill_id,level,source&source=eq.CV_CONFIRMED", {
    headers: headers(user.token),
  });
  const confirmedMap = new Map((confirmed.json ?? []).map((row) => [row.skill_id, row]));
  const expectedConfirmedIds = [...user.skills].sort();
  const actualConfirmedIds = [...confirmedMap.keys()].sort();
  const levelsCorrect = user.skills.every((id) => confirmedMap.get(id)?.level === (levels[id] ?? 4));
  record(user, "suggestion_review", "only approved skills reach graduate_skills with the reviewed proficiency",
    confirmed.status === 200 &&
    expectedConfirmedIds.length === actualConfirmedIds.length &&
    expectedConfirmedIds.every((id, index) => id === actualConfirmedIds[index]) &&
    levelsCorrect && !confirmedMap.has(user.reject_skill_id),
    { status: confirmed.status, expected: expectedConfirmedIds, actual: actualConfirmedIds,
      rejectedSkillPresent: confirmedMap.has(user.reject_skill_id) });
  const duplicateParse = await post("/functions/v1/parse-cv", user.token, { cv_document_id: user.cvId });
  record(user, "suggestion_review", "a completed CV cannot be parsed a second time",
    duplicateParse.status === 409 && duplicateParse.json?.error === "CV_ALREADY_PARSED",
    { status: duplicateParse.status, body: duplicateParse.json ?? duplicateParse.text });
}
async function testStructuredPersistence(user) {
  if (!user.token) {
    record(user, "structured_records", "experience, certification and course persistence can be checked", false);
    return;
  }
  const [experience, certification, course] = await Promise.all([
    request("/rest/v1/career_history?select=company_name,job_title,field,start_date,end_date,source&company_name=eq." + encodeURIComponent(user.experience.company), {
      headers: headers(user.token),
    }),
    request("/rest/v1/certifications?select=title,issuer,source&title=eq." + encodeURIComponent(user.certification.title), {
      headers: headers(user.token),
    }),
    request("/rest/v1/courses?select=title,provider,source&title=eq." + encodeURIComponent(user.course.title), {
      headers: headers(user.token),
    }),
  ]);
  record(user, "structured_records", "confirmed experience is stored with correct employer, role, dates and provenance",
    experience.status === 200 && experience.json?.length === 1 &&
    experience.json[0].company_name === user.experience.company &&
    experience.json[0].job_title === user.experience.title &&
    experience.json[0].source === "CV_CONFIRMED" &&
    Boolean(experience.json[0].start_date) && Boolean(experience.json[0].end_date),
    { status: experience.status, body: experience.json ?? experience.text });
  record(user, "structured_records", "confirmed certification is stored with correct title, issuer and provenance",
    certification.status === 200 && certification.json?.length === 1 &&
    certification.json[0].issuer === user.certification.issuer &&
    certification.json[0].source === "CV_CONFIRMED",
    { status: certification.status, body: certification.json ?? certification.text });
  record(user, "structured_records", "confirmed course is stored with correct title, provider and provenance",
    course.status === 200 && course.json?.length === 1 &&
    course.json[0].provider === user.course.provider &&
    course.json[0].source === "CV_CONFIRMED",
    { status: course.status, body: course.json ?? course.text });
}
async function opportunityId(user, seedKey) {
  const result = await request("/rest/v1/opportunities?select=id,seed_key,title,type&seed_key=eq." + encodeURIComponent(seedKey), {
    headers: headers(user.token),
  });
  return result.json?.[0]?.id ?? null;
}
async function testCareerAndRecommendations(user) {
  if (!user.token) {
    record(user, "career_classification", "career profile is inferred from confirmed skills", false);
    record(user, "recommendations", "recommendations can be computed for this graduate", false);
    return;
  }
  const first = await post("/functions/v1/recommend", user.token, {});
  const profile = first.json?.career_profile;
  const paths = profile?.paths ?? [];
  const actualPaths = paths.map((item) => item.id).sort();
  const expectedPaths = [...user.target_paths].sort();
  record(user, "career_classification", "career profile includes every expected track for this graduate",
    first.status === 200 && expectedPaths.every((id) => actualPaths.includes(id)),
    { status: first.status, expectedPaths, actualPaths, body: first.json ?? first.text });
  record(user, "career_classification", "career profile does not infer unrelated tracks from generic skills",
    first.status === 200 && actualPaths.length === expectedPaths.length &&
    actualPaths.every((id) => expectedPaths.includes(id)),
    { expectedPaths, actualPaths });
  record(user, "career_classification", "primary path is one of the graduate's expected tracks",
    first.status === 200 && user.target_paths.includes(profile?.primary_path?.id),
    { primary: profile?.primary_path?.id, expected: user.target_paths });
  record(user, "career_classification", "career path scores and skill evidence are valid and explainable",
    paths.length > 0 && paths.every((item) =>
      Number.isFinite(item.score) && item.score >= 0 && item.score <= 100 &&
      item.core_match_count >= item.required_core_match_count &&
      Array.isArray(item.skill_evidence) && item.skill_evidence.length > 0 &&
      item.skill_evidence.every((skill) => skill.level >= 1 && skill.level <= 5)),
    { paths: paths.map((item) => ({
      id: item.id, score: item.score, core: item.matched_core_skill_ids,
      supporting: item.matched_supporting_skill_ids,
      specialization: item.specialization_signal_skill_ids,
      missing: item.missing_core_skill_ids,
    })) });
  record(user, "career_classification", "career profile includes the no-hiring-probability disclaimer",
    typeof profile?.disclaimer === "string" && /ليست احتمال قبول/.test(profile.disclaimer),
    { disclaimer: profile?.disclaimer });

  user.recommendationItems = first.json?.items ?? [];
  user._careerScores = paths.map((item) => ({ id: item.id, score: item.score }));
  record(user, "recommendations", "confirming CV skills invalidates and recomputes the empty baseline snapshot",
    first.status === 200 && first.json?.source === "computed" &&
    user.baselineRecommendation?.json?.career_profile?.paths?.length === 0,
    { baselineSource: user.baselineRecommendation?.json?.source, refreshedSource: first.json?.source,
      expectedPaths, actualPaths });
  record(user, "recommendations", "recommend endpoint returns deterministic recommendations with the current model",
    first.status === 200 && first.json?.source === "computed" &&
    first.json?.ai_mode === "deterministic" &&
    first.json?.model_version === "deterministic-v3-career-intelligence" &&
    Array.isArray(first.json?.items),
    { status: first.status, source: first.json?.source, model_version: first.json?.model_version });
  const validRecommendations = user.recommendationItems.every((item) =>
    Number.isFinite(item.score) && item.score >= 0 && item.score <= 100 &&
    ["HIGH", "GOOD", "MEDIUM", "LOW"].includes(item.band) &&
    item.opportunity?.status === "ACTIVE");
  record(user, "recommendations", "every returned recommendation has a valid score, band and open opportunity",
    validRecommendations,
    { count: user.recommendationItems.length, invalid: user.recommendationItems.filter((item) =>
      !(Number.isFinite(item.score) && item.score >= 0 && item.score <= 100 &&
        ["HIGH", "GOOD", "MEDIUM", "LOW"].includes(item.band) && item.opportunity?.status === "ACTIVE")
    ).map((item) => ({ id: item.opportunity_id, score: item.score, band: item.band, status: item.opportunity?.status })) });

  const expectedTitles = user.recommendation_titles ?? [];
  const foundTitles = expectedTitles.filter((title) =>
    user.recommendationItems.some((item) => item.opportunity?.title === title));
  record(user, "recommendations", "catalogue contains the configured track-relevant recommendation opportunities",
    expectedTitles.length === 0 || foundTitles.length === expectedTitles.length,
    { expectedTitles, foundTitles, returnedTitles: user.recommendationItems.map((item) => item.opportunity?.title) });

  const cached = await post("/functions/v1/recommend", user.token, {});
  record(user, "recommendations", "second recommendation request serves cache without losing the career profile",
    cached.status === 200 && cached.json?.source === "cache" &&
    user.target_paths.every((id) => (cached.json?.career_profile?.paths ?? []).some((path) => path.id === id)),
    { status: cached.status, source: cached.json?.source, paths: cached.json?.career_profile?.paths?.map((item) => item.id) });

  const ownRows = await request("/rest/v1/recommendations?select=graduate_id,score,band", {
    headers: headers(user.token),
  });
  record(user, "recommendations", "recommendation rows are visible only for this graduate and contain valid scores",
    ownRows.status === 200 && (ownRows.json ?? []).every((row) => row.graduate_id === user.authId) &&
    (ownRows.json ?? []).every((row) => Number.isFinite(Number(row.score)) &&
      ["HIGH", "GOOD", "MEDIUM", "LOW"].includes(row.band)),
    { status: ownRows.status, count: ownRows.json?.length,
      foreignRows: (ownRows.json ?? []).filter((row) => row.graduate_id !== user.authId).length });
}
async function testGraduateWorkflows(user) {
  if (!user.token || !user.authId || !user.cvId) {
    record(user, "graduate_workflows", "save, apply, withdraw and event registration prerequisites are available", false);
    return;
  }
  const jobId = await opportunityId(user, "job-grad-2024-only");
  const eventId = await opportunityId(user, "evt-tech-conf");
  record(user, "graduate_workflows", "open graduate job and conference exist in the read-only catalogue",
    Boolean(jobId && eventId), { jobId, eventId });
  if (!jobId || !eventId) return;

  const saved = await request("/rest/v1/saved_opportunities", {
    method: "POST",
    headers: headers(user.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({ graduate_id: user.authId, opportunity_id: jobId }),
  });
  record(user, "graduate_workflows", "graduate can save an opportunity they own",
    saved.status === 201 && saved.json?.length === 1,
    { status: saved.status, body: saved.json ?? saved.text });
  const savedRead = await request("/rest/v1/saved_opportunities?select=id,opportunity_id&opportunity_id=eq." + jobId, {
    headers: headers(user.token),
  });
  record(user, "graduate_workflows", "saved opportunity is returned to its owner",
    savedRead.status === 200 && savedRead.json?.some((row) => row.opportunity_id === jobId),
    { status: savedRead.status, body: savedRead.json ?? savedRead.text });
  const savedDelete = await request("/rest/v1/saved_opportunities?graduate_id=eq." + user.authId + "&opportunity_id=eq." + jobId, {
    method: "DELETE", headers: headers(user.token),
  });
  const afterSaveDelete = await request("/rest/v1/saved_opportunities?select=id&opportunity_id=eq." + jobId, {
    headers: headers(user.token),
  });
  record(user, "graduate_workflows", "graduate can remove their saved opportunity",
    savedDelete.ok && afterSaveDelete.status === 200 && afterSaveDelete.json?.length === 0,
    { deleteStatus: savedDelete.status, remaining: afterSaveDelete.json?.length });

  const applied = await post("/rest/v1/rpc/apply_for_job", user.token, {
    p_opportunity_id: jobId, p_cv_document_id: user.cvId, p_note: "Ten-user cohort " + round + ": " + user.track,
  });
  const applicationId = applied.json?.id ?? null;
  record(user, "graduate_workflows", "graduate applies using their own completed CV and receives SUBMITTED",
    applied.status === 200 && Boolean(applicationId) && applied.json?.status === "SUBMITTED",
    { status: applied.status, body: applied.json ?? applied.text });
  const duplicateApplication = await post("/rest/v1/rpc/apply_for_job", user.token, {
    p_opportunity_id: jobId, p_cv_document_id: user.cvId, p_note: "duplicate guard test",
  });
  record(user, "graduate_workflows", "duplicate application is rejected with ALREADY_APPLIED",
    duplicateApplication.status === 409 &&
    (duplicateApplication.json?.message === "ALREADY_APPLIED" || duplicateApplication.json?.code === "ALREADY_APPLIED"),
    { status: duplicateApplication.status, body: duplicateApplication.json ?? duplicateApplication.text });
  if (applicationId) {
    const withdrawn = await post("/rest/v1/rpc/withdraw_application", user.token, { p_application_id: applicationId });
    record(user, "graduate_workflows", "graduate can withdraw their own SUBMITTED application",
      withdrawn.status === 200 && withdrawn.json?.status === "WITHDRAWN",
      { status: withdrawn.status, body: withdrawn.json ?? withdrawn.text });
    const appHistory = await request("/rest/v1/application_status_history?select=old_status,new_status,source_type&application_id=eq." + applicationId, {
      headers: headers(user.token),
    });
    record(user, "graduate_workflows", "application history records SUBMITTED then WITHDRAWN",
      appHistory.status === 200 &&
      appHistory.json?.some((row) => row.new_status === "SUBMITTED" && row.source_type === "APP_ACTION") &&
      appHistory.json?.some((row) => row.new_status === "WITHDRAWN" && row.source_type === "APP_ACTION"),
      { status: appHistory.status, body: appHistory.json ?? appHistory.text });
  }

  const registered = await post("/rest/v1/rpc/register_for_event", user.token, { p_opportunity_id: eventId });
  record(user, "graduate_workflows", "graduate registers for the open conference",
    registered.status === 200 && registered.json?.status === "REGISTERED",
    { status: registered.status, body: registered.json ?? registered.text });
  const duplicateRegistration = await post("/rest/v1/rpc/register_for_event", user.token, { p_opportunity_id: eventId });
  record(user, "graduate_workflows", "duplicate event registration is rejected",
    duplicateRegistration.status === 409 &&
    (duplicateRegistration.json?.message === "ALREADY_REGISTERED" || duplicateRegistration.json?.code === "ALREADY_REGISTERED"),
    { status: duplicateRegistration.status, body: duplicateRegistration.json ?? duplicateRegistration.text });
  const cancelled = await post("/rest/v1/rpc/cancel_event_registration", user.token, { p_opportunity_id: eventId });
  record(user, "graduate_workflows", "graduate can cancel their event registration",
    cancelled.status === 200 && cancelled.json?.status === "CANCELLED",
    { status: cancelled.status, body: cancelled.json ?? cancelled.text });
  const reRegistered = await post("/rest/v1/rpc/register_for_event", user.token, { p_opportunity_id: eventId });
  record(user, "graduate_workflows", "graduate can register again after cancellation",
    reRegistered.status === 200 && reRegistered.json?.status === "REGISTERED",
    { status: reRegistered.status, body: reRegistered.json ?? reRegistered.text });
  if (reRegistered.status === 200) {
    await post("/rest/v1/rpc/cancel_event_registration", user.token, { p_opportunity_id: eventId });
  }
}
async function testInsightsAndFeedback(user) {
  if (!user.token) {
    record(user, "insights_feedback", "career market insights and feedback are accessible", false);
    return;
  }
  const market = await post("/rest/v1/rpc/get_career_market_insights", user.token, {});
  record(user, "insights_feedback", "career market insights expose platform demand and this graduate's confirmed skills",
    market.status === 200 &&
    market.json?.market_basis?.includes("active JOB") &&
    Array.isArray(market.json?.top_demand_skills) &&
    Array.isArray(market.json?.priority_skill_gaps) &&
    user.skills.every((id) => (market.json?.your_skills ?? []).some((skill) => skill.skill_id === id)) &&
    Number(market.json?.your_experience_years) > 0,
    { status: market.status, marketBasis: market.json?.market_basis,
      experienceYears: market.json?.your_experience_years,
      returnedSkills: (market.json?.your_skills ?? []).map((skill) => skill.skill_id) });
  const insights = await post("/rest/v1/rpc/get_my_insights", user.token, {});
  record(user, "insights_feedback", "personal graduate insights endpoint responds with a completion profile",
    insights.status === 200 && insights.json && typeof insights.json === "object",
    { status: insights.status, body: insights.json ?? insights.text });
  const gaps = await post("/rest/v1/rpc/get_skill_gaps", user.token, {});
  record(user, "insights_feedback", "skill-gap endpoint responds with a structured result",
    gaps.status === 200 && gaps.json !== null,
    { status: gaps.status, body: gaps.json ?? gaps.text });

  const feedbackTarget = user.recommendationItems[0];
  if (!feedbackTarget?.opportunity_id) {
    record(user, "insights_feedback", "a recommendation can receive user feedback", false,
      { recommendations: user.recommendationItems.length });
    return;
  }
  const feedback = await post("/rest/v1/rpc/record_recommendation_interaction", user.token, {
    p_opportunity_id: feedbackTarget.opportunity_id,
    p_interaction_type: "DISMISS",
  });
  record(user, "insights_feedback", "graduate can dismiss a recommendation through the feedback RPC",
    feedback.status === 200 && feedback.json?.recorded === true,
    { status: feedback.status, body: feedback.json ?? feedback.text });
  const recomputed = await post("/functions/v1/recommend", user.token, {});
  record(user, "insights_feedback", "dismissal invalidates the cache and removes that item from refreshed recommendations",
    recomputed.status === 200 && recomputed.json?.source === "computed" &&
    !(recomputed.json?.items ?? []).some((item) => item.opportunity_id === feedbackTarget.opportunity_id),
    { status: recomputed.status, source: recomputed.json?.source,
      dismissedId: feedbackTarget.opportunity_id,
      stillVisible: (recomputed.json?.items ?? []).some((item) => item.opportunity_id === feedbackTarget.opportunity_id) });
  const interaction = await request("/rest/v1/recommendation_interactions?select=interaction_type,graduate_id&opportunity_id=eq." + feedbackTarget.opportunity_id, {
    headers: headers(user.token),
  });
  record(user, "insights_feedback", "feedback interaction is persisted and remains owner-scoped",
    interaction.status === 200 &&
    interaction.json?.some((row) => row.interaction_type === "DISMISS" && row.graduate_id === user.authId) &&
    interaction.json?.every((row) => row.graduate_id === user.authId),
    { status: interaction.status, rows: interaction.json ?? interaction.text });
  const notifications = await request("/rest/v1/notifications?select=id,type&order=created_at.asc", {
    headers: headers(user.token),
  });
  record(user, "insights_feedback", "application and event workflows create this graduate's notifications",
    notifications.status === 200 &&
    notifications.json?.some((row) => row.type === "APPLICATION_SUBMITTED") &&
    notifications.json?.some((row) => row.type === "EVENT_REGISTERED"),
    { status: notifications.status, types: (notifications.json ?? []).map((row) => row.type) });
}
async function testPrivacy(users) {
  for (let index = 0; index < users.length; index++) {
    const user = users[index];
    const other = users[(index + 1) % users.length];
    if (!user.token || !other.authId || !other.cvId || !other.storagePath) {
      record(user, "cv_storage_privacy", "peer identity and CV are present for cross-account privacy checks", false);
      continue;
    }
    const foreignProfile = await request("/rest/v1/profiles?select=id&id=eq." + other.authId, {
      headers: headers(user.token),
    });
    const foreignGraduateSkills = await request("/rest/v1/graduate_skills?select=skill_id&graduate_id=eq." + other.authId, {
      headers: headers(user.token),
    });
    const foreignDocument = await getById("cv_documents", "id,graduate_id", other.cvId, user.token);
    const foreignSuggestions = await request("/rest/v1/cv_suggestions?select=id&cv_document_id=eq." + other.cvId, {
      headers: headers(user.token),
    });
    const foreignRecommendations = await request("/rest/v1/recommendations?select=graduate_id&graduate_id=eq." + other.authId, {
      headers: headers(user.token),
    });
    const foreignFile = await request("/storage/v1/object/cv-documents/" + encodePath(other.storagePath), {
      headers: headers(user.token),
    });
    const foreignParse = await post("/functions/v1/parse-cv", user.token, { cv_document_id: other.cvId });
    record(user, "cv_storage_privacy", "another graduate's profile, skills, CV metadata and suggestions are hidden by RLS",
      foreignProfile.status === 200 && foreignProfile.json?.length === 0 &&
      foreignGraduateSkills.status === 200 && foreignGraduateSkills.json?.length === 0 &&
      foreignDocument.status === 200 && foreignDocument.json?.length === 0 &&
      foreignSuggestions.status === 200 && foreignSuggestions.json?.length === 0,
      {
        peer: other.code,
        profile: foreignProfile.json ?? foreignProfile.text,
        skills: foreignGraduateSkills.json ?? foreignGraduateSkills.text,
        document: foreignDocument.json ?? foreignDocument.text,
        suggestions: foreignSuggestions.json ?? foreignSuggestions.text,
      });
    record(user, "cv_storage_privacy", "another graduate's CV file cannot be downloaded or parsed",
      !foreignFile.ok && foreignParse.status === 404,
      { downloadStatus: foreignFile.status, parseStatus: foreignParse.status,
        parseBody: foreignParse.json ?? foreignParse.text });
    record(user, "cv_storage_privacy", "recommendation rows cannot leak another graduate's identity",
      foreignRecommendations.status === 200 && foreignRecommendations.json?.length === 0,
      { status: foreignRecommendations.status, body: foreignRecommendations.json ?? foreignRecommendations.text });
  }
}
function grade(user) {
  const categories = {};
  let weighted = 0;
  for (const [key, weight] of Object.entries(CATEGORY_WEIGHTS)) {
    const checks = user.checks.filter((item) => item.category === key);
    const passed = checks.filter((item) => item.passed).length;
    const rate = checks.length ? passed / checks.length : 0;
    const score = checks.length ? Math.round(rate * 100) : 0;
    const points = weight * rate;
    categories[key] = {
      weight, passed, total: checks.length, score,
      weighted_points: Math.round(points * 100) / 100,
      failed_checks: checks.filter((item) => !item.passed).map((item) => ({
        name: item.name, details: item.details ?? null,
      })),
    };
    weighted += points;
  }
  const passed = user.checks.filter((item) => item.passed).length;
  return {
    code: user.code, name: user.name, track: user.track, target_paths: user.target_paths,
    email: user.email, career_match_scores: user._careerScores ?? [],
    score: Math.round(weighted), checks_passed: passed, checks_total: user.checks.length,
    categories,
    failed_checks: user.checks.filter((item) => !item.passed).map((item) => ({
      category: item.category, name: item.name, details: item.details ?? null,
    })),
  };
}
async function cleanup() {
  for (const user of users) {
    if (user.storagePath) {
      const removed = await request("/storage/v1/object/cv-documents", {
        method: "DELETE",
        headers: headers(service, { "Content-Type": "application/json" }),
        body: JSON.stringify({ prefixes: [user.storagePath] }),
      });
      if (!removed.ok && removed.status !== 404) {
        cleanupFailures.push({ user: user.code, action: "remove storage object", status: removed.status });
      }
    }
    if (user.authId) {
      const removed = await request("/auth/v1/admin/users/" + user.authId, {
        method: "DELETE", headers: headers(service),
      });
      if (!removed.ok && removed.status !== 404) {
        cleanupFailures.push({ user: user.code, action: "delete synthetic Auth user", status: removed.status,
          body: removed.json ?? removed.text });
      }
    }
  }
}

try {
  console.log("CAREER COHORT " + round.toUpperCase() + " - " + users.length + " independent graduate accounts");
  for (const user of users) await createUser(user);
  // Complete every functional layer for one graduate before starting the next graduate.
  for (const user of users) {
    console.log("BEGIN USER JOURNEY " + user.code + " / " + user.track);
    await primeRecommendations(user);
    await uploadAndParse(user);
    await testStructuredPersistence(user);
    await testCareerAndRecommendations(user);
    await testGraduateWorkflows(user);
    await testInsightsAndFeedback(user);
    console.log("END USER JOURNEY " + user.code + " / " + user.track);
  }
  // All ten accounts exist together, so cross-account RLS and private Storage are checked in a full ring.
  await testPrivacy(users);
} catch (error) {
  console.error("CAREER COHORT HARNESS ERROR", error);
  const target = users.find((user) => user.checks.length === 0) ?? users[0];
  if (target) record(target, "profile_auth", "cohort harness completed without an unhandled exception", false, String(error));
} finally {
  await cleanup();
}

for (const user of users) {
  const profile = grade(user);
  console.log("USER_SCORE|" + profile.code + "|" + profile.score + "/100|" +
    profile.checks_passed + "/" + profile.checks_total + "|" + profile.track);
}
const graded = users.map(grade);
const overall = Math.round(graded.reduce((sum, item) => sum + item.score, 0) / graded.length);
const allPassed = graded.every((item) => item.score === 100) && cleanupFailures.length === 0;
const categorySummary = Object.fromEntries(Object.keys(CATEGORY_WEIGHTS).map((key) => {
  const values = graded.map((item) => item.categories[key]);
  const mean = values.reduce((sum, item) => sum + item.score, 0) / values.length;
  return [key, {
    weight: CATEGORY_WEIGHTS[key], average_score: Math.round(mean),
    passed: values.reduce((n, item) => n + item.passed, 0),
    total: values.reduce((n, item) => n + item.total, 0),
  }];
}));
const report = {
  round, run_id: runId, total_users: users.length, overall_score: overall, passed: allPassed,
  checks_passed: graded.reduce((sum, item) => sum + item.checks_passed, 0),
  checks_total: graded.reduce((sum, item) => sum + item.checks_total, 0),
  category_summary: categorySummary, users: graded, cleanup_failures: cleanupFailures,
};
mkdirSync("career-cohort-reports", { recursive: true });
writeFileSync("career-cohort-reports/career-cohort-" + round + ".json", JSON.stringify(report, null, 2) + "\n");
const md = [
  "# Career Cohort " + round.toUpperCase() + " Report",
  "",
  "- Run ID: " + runId,
  "- Users: " + report.total_users,
  "- Overall QA score: **" + overall + "/100**",
  "- Checks: " + report.checks_passed + "/" + report.checks_total,
  "- Fully passed: **" + (allPassed ? "YES" : "NO") + "**",
  "",
  "| User | Track | Career path score(s) | QA score | Checks |",
  "|---|---|---|---:|---:|",
  ...graded.map((item) => {
    const scores = (item.career_match_scores ?? []).map((path) => path.id + ": " + path.score + "/100").join(", ") || "No inferred path";
    return "| " + item.name + " (" + item.code + ") | " + item.track + " | " + scores + " | " +
      item.score + "/100 | " + item.checks_passed + "/" + item.checks_total + " |";
  }),
  "",
  "## Component averages",
  "",
  "| Component | Weight | Average score | Checks passed |",
  "|---|---:|---:|---:|",
  ...Object.entries(categorySummary).map(([key, value]) =>
    "| " + key + " | " + value.weight + "% | " + value.average_score + "/100 | " +
    value.passed + "/" + value.total + " |"),
  "",
  "## Failed checks",
  "",
  ...graded.flatMap((item) => item.failed_checks.map((check) =>
    "- **" + item.code + " / " + check.category + " / " + check.name + "**: " +
    JSON.stringify(check.details)
  )),
  ...(cleanupFailures.length ? ["", "## Cleanup failures", "", ...cleanupFailures.map((item) => "- " + JSON.stringify(item))] : []),
].join("\n") + "\n";
writeFileSync("career-cohort-reports/career-cohort-" + round + ".md", md);
console.log("CAREER_COHORT_REPORT_PATH|career-cohort-reports/career-cohort-" + round + ".json");
console.log("CAREER_COHORT_SCORE|" + round + "|" + overall + "/100|" +
  report.checks_passed + "/" + report.checks_total + "|" + (allPassed ? "PASS" : "FAIL"));
console.log("CAREER_COHORT_REPORT|" + JSON.stringify({
  round, overall_score: overall, category_summary: categorySummary,
  users: graded.map((item) => ({
    code: item.code, track: item.track, score: item.score,
    checks_passed: item.checks_passed, checks_total: item.checks_total,
    failed_checks: item.failed_checks.length,
  })),
  cleanup_failures: cleanupFailures.length,
}));
if (!allPassed) process.exitCode = 1;
