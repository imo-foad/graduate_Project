// Executable local-only CV extraction evaluation (issue #24).
//
// Generates every document from the versioned synthetic corpus, sends it through the real local
// parse-cv Edge Function, reads the persisted suggestions, and reports per-field precision/recall.
// No OCR, paid API or hosted model is used. CV_PARSE has a five-token bucket per account, so the
// corpus is split across a dedicated benchmark account plus disposable synthetic accounts created
// with the local service role. No rate-limit rule is changed or bypassed.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { buildFixture } from "./cv-fixture-generator.mjs";
import {
  aggregateScores,
  CATEGORIES,
  gateReport,
  QUALITY_GATES,
  scoreScenario,
  validateCorpus,
} from "./cv-parser-metrics.mjs";

const corpus = JSON.parse(readFileSync(new URL("../tests/fixtures/cv-parser/corpus.v1.json", import.meta.url), "utf8"));
const corpusErrors = validateCorpus(corpus);
assert.deepEqual(corpusErrors, [], "synthetic CV corpus is malformed: " + corpusErrors.join("; "));

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase CV evaluation environment is incomplete");
const parsedBase = new URL(base);
assert.ok(parsedBase.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(parsedBase.hostname) &&
  parsedBase.port === "54321", "refusing CV evaluation outside the disposable local Supabase API");

// Dedicated benchmark identity, separate from the CV integration and rate-limit accounts.
const userEmail = "graduate.cyber@alumni.test";
const SYNTHETIC_PREFIX = "cv-eval-" + randomUUID().slice(0, 8);
const DOCUMENTS_PER_ACCOUNT = 5;

const headers = (key, token, more = {}) => ({
  apikey: key,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...more,
});
async function responseJson(res) {
  const raw = await res.text();
  let data = null;
  try { data = raw ? JSON.parse(raw) : null; } catch { /* non-JSON response */ }
  return { status: res.status, data, raw };
}
async function request(path, init = {}) {
  return responseJson(await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) }));
}
async function login(email, credential = password) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(anon, null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password: credential }),
  });
  assert.equal(r.status, 200, "CV evaluation login failed for " + email + ": " + r.raw);
  return { token: r.data.access_token, id: r.data.user.id, email };
}
async function createSyntheticAccount(index) {
  const email = `${SYNTHETIC_PREFIX}-${index}@alumni.test`;
  // Each benchmark account gets its own password; the demo password is only for seeded accounts.
  const credential = "CvEval-" + randomUUID().replace(/-/g, "").slice(0, 20);
  const created = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: headers(service, service, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email,
      password: credential,
      email_confirm: true,
      user_metadata: { full_name: "Synthetic CV Benchmark " + index },
    }),
  });
  assert.ok(created.status === 200 || created.status === 201, "could not create synthetic benchmark account: " + created.raw);
  const id = created.data?.id;
  assert.ok(typeof id === "string" && id.length > 0, "synthetic benchmark account creation returned no user id");
  // Record the account before the password grant, so cleanup also deletes it if that login fails.
  const account = { id, email, token: null, synthetic: true };
  accounts.push(account);
  const session = await login(email, credential);
  assert.equal(session.id, id, "CV evaluation login resolved a different user than the one created");
  account.token = session.token;
  return account;
}
const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");
async function upload(account, scenario, bytes, mime) {
  const path = `${account.id}/cv-eval-${scenario.id}-${randomUUID()}.${scenario.format}`;
  const up = await request("/storage/v1/object/cv-documents/" + encodePath(path), {
    method: "POST",
    headers: headers(anon, account.token, { "Content-Type": mime, "x-upsert": "false" }),
    body: bytes,
  });
  assert.ok(up.status === 200 || up.status === 201, scenario.id + " upload failed: " + up.raw);
  const meta = await request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(anon, account.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({
      graduate_id: account.id,
      storage_path: path,
      file_type: scenario.format,
      size_bytes: bytes.length,
    }),
  });
  assert.equal(meta.status, 201, scenario.id + " metadata failed: " + meta.raw);
  return { id: meta.data[0].id, path };
}
async function parse(account, id) {
  return request("/functions/v1/parse-cv", {
    method: "POST",
    headers: headers(anon, account.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ cv_document_id: id }),
  });
}
async function worker() {
  return request("/functions/v1/cleanup-cv-objects", {
    method: "POST",
    headers: headers(service, service, { "Content-Type": "application/json" }),
    body: "{}",
  });
}

const accounts = [await login(userEmail)];
const cleanupIssues = [];
const uploaded = [];
const records = [];
try {
  for (const [index, scenario] of corpus.scenarios.entries()) {
    const bucket = Math.floor(index / DOCUMENTS_PER_ACCOUNT);
    if (bucket >= accounts.length) await createSyntheticAccount(bucket);
    const account = accounts[bucket];
    assert.ok(account, "missing evaluation account for " + scenario.id);

    const fixture = buildFixture(scenario);
    assert.ok(fixture.bytes.length > 0, scenario.id + " generated an empty document");
    const file = await upload(account, scenario, fixture.bytes, fixture.mime);
    uploaded.push({ ...file, account });

    const parsed = await parse(account, file.id);
    assert.equal(parsed.status, 200, scenario.id + " parse failed: " + parsed.raw);
    assert.equal(parsed.data?.status, "DONE", scenario.id + " did not reach DONE");
    assert.equal(parsed.data?.confirmation_required, true, scenario.id + " must require graduate review");
    const rows = await request("/rest/v1/cv_suggestions?select=kind,payload,status&cv_document_id=eq." + file.id, {
      headers: headers(anon, account.token),
    });
    assert.equal(rows.status, 200, scenario.id + " suggestion read failed: " + rows.raw);
    const suggestions = rows.data ?? [];
    assert.ok(suggestions.every((row) => row.status === "PENDING"), scenario.id + " produced non-pending suggestions");

    const actual = {
      skills: suggestions.filter((row) => row.kind === "SKILL").map((row) => row.payload?.skill_id).filter(Boolean),
      experiences: suggestions.filter((row) => row.kind === "EXPERIENCE").map((row) => row.payload ?? {}),
      certifications: suggestions.filter((row) => row.kind === "CERTIFICATION").map((row) => row.payload ?? {}),
      courses: suggestions.filter((row) => row.kind === "COURSE").map((row) => row.payload ?? {}),
    };
    const scored = scoreScenario(scenario, actual);
    records.push({
      id: scenario.id,
      format: scenario.format,
      language: scenario.language,
      layout: scenario.layout,
      fixture_sha256_length: fixture.bytes.length,
      pending_suggestions: true,
      suggestions: {
        skills: actual.skills.length,
        experiences: actual.experiences.length,
        certifications: actual.certifications.length,
        courses: actual.courses.length,
      },
      ...scored,
    });
  }
} finally {
  // Owner RPC first (the only supported client path), then drain the durable Storage cleanup queue.
  for (const item of uploaded) {
    await request("/rest/v1/rpc/delete_cv_document", {
      method: "POST",
      headers: headers(anon, item.account.token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ p_cv_document_id: item.id }),
    }).catch(() => {});
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    const drained = await worker();
    if (drained.status !== 200 || (drained.data?.processed ?? 0) === 0) break;
  }
  for (const account of accounts) {
    if (!account.synthetic) continue;
    const removed = await request("/auth/v1/admin/users/" + account.id, {
      method: "DELETE",
      headers: headers(service, service),
    }).catch(() => null);
    const after = await request("/auth/v1/admin/users/" + account.id, { headers: headers(service, service) }).catch(() => null);
    if (!after || after.status !== 404) {
      cleanupIssues.push(`${account.email}: delete=${removed?.status ?? "error"} read=${after?.status ?? "error"}`);
    }
  }
  // The seeded benchmark identity is shared with other suites and must survive this run.
  const seeded = await request("/auth/v1/admin/users/" + accounts[0].id, { headers: headers(service, service) });
  if (seeded.status !== 200) cleanupIssues.push("seeded benchmark account is missing: read=" + seeded.status);
}

assert.deepEqual(cleanupIssues, [], "CV evaluation cleanup left Auth users in an unexpected state: " + cleanupIssues.join("; "));

const expectedIds = corpus.scenarios.map((scenario) => scenario.id).sort();
const evaluatedIds = records.map((record) => record.id).sort();
assert.deepEqual(evaluatedIds, expectedIds, "every corpus fixture must be evaluated exactly once");

const aggregate = aggregateScores(records);
const gates = gateReport(aggregate);
const byId = new Map(records.map((record) => [record.id, record]));

// Explicit regression assertions, independent of the aggregate gates.
const arabic = byId.get("ar-docx-attached-skills-v1");
assert.ok(arabic, "Arabic DOCX regression fixture is missing");
assert.ok(!arabic.metrics.skills.missed_fields.includes("SQL"), "Arabic DOCX regression: SQL was missed");
assert.ok(!arabic.metrics.skills.missed_fields.includes("KOTLIN"), "Arabic DOCX regression: Kotlin was missed");

const twoColumn = byId.get("en-pdf-two-column-sidebar-v1");
assert.ok(twoColumn, "multi-column PDF fixture is missing");
assert.deepEqual(twoColumn.metrics.experience_fields.missed_fields, [], "multi-column PDF lost experience fields");
assert.deepEqual(twoColumn.metrics.experience_fields.false_positive_fields, [], "multi-column PDF merged experience fields");

const negatives = records.filter((record) => record.id.startsWith("negative-"));
assert.ok(negatives.length >= 2, "the corpus must contain at least two negative fixtures");
for (const negative of negatives) {
  assert.deepEqual(negative.violations, [], negative.id + " extracted a forbidden field");
  assert.equal(negative.total_suggestions, 0, negative.id + " produced suggestions that are not in its ground truth");
}
for (const record of records) {
  if (record.id.startsWith("negative-")) continue;
  assert.ok(record.total_suggestions > 0, record.id + " produced no suggestions, which would hide a broken fixture");
}

const report = {
  evaluation: "synthetic local CV parser field-level benchmark",
  corpus_version: corpus.version,
  generated_at: new Date().toISOString(),
  formats: {
    pdf: corpus.scenarios.filter((scenario) => scenario.format === "pdf").length,
    docx: corpus.scenarios.filter((scenario) => scenario.format === "docx").length,
    scenarios: corpus.scenarios.length,
    negative_scenarios: negatives.length,
  },
  supported_formats: ["text-based PDF", "DOCX document.xml text, tables and bullets"],
  unsupported_formats: ["scanned/image-only PDF (OCR intentionally not implemented or invoked)"],
  quality_gates: QUALITY_GATES,
  limitations: [
    "Synthetic, curated documents only: these results do not establish accuracy on real-world CVs.",
    "Arabic PDF text is not evaluated because the synthetic PDF generator uses a Latin font; Arabic is evaluated through DOCX.",
    "A representative, owner-approved, consented and anonymized real-CV corpus is still required before any real-world accuracy claim.",
  ],
  regression_checks: {
    arabic_docx_sql_and_kotlin: true,
    multi_column_pdf_employer_and_title_preserved: true,
    negative_fixtures_clean: true,
  },
  corpus_integrity: {
    ids_evaluated: evaluatedIds.length,
    ids_expected: expectedIds.length,
    duplicate_ids: false,
  },
  documents: records,
  aggregate,
  gates,
};

mkdirSync(".ci-logs", { recursive: true });
writeFileSync(".ci-logs/cv-parser-evaluation.json", JSON.stringify(report, null, 2) + "\n");
console.log("CV PARSER EVALUATION (synthetic corpus v" + corpus.version + ")");
console.log("documents: " + corpus.scenarios.length + " (" + report.formats.pdf + " PDF, " + report.formats.docx + " DOCX)");
for (const category of CATEGORIES) {
  const score = aggregate[category];
  console.log(`  ${category.padEnd(22)} TP=${score.true_positive} FP=${score.false_positive} FN=${score.false_negative} ` +
    `P=${(score.precision * 100).toFixed(1)}% R=${(score.recall * 100).toFixed(1)}% F1=${(score.f1 * 100).toFixed(1)}%`);
}
for (const record of records) {
  const missed = CATEGORIES.reduce((sum, category) => sum + record.metrics[category].false_negative, 0);
  const falsePositives = CATEGORIES.reduce((sum, category) => sum + record.metrics[category].false_positive, 0);
  console.log(`  ${record.id} (${record.format}) missed=${missed} false_positives=${falsePositives} violations=${record.violations.length}`);
}
if (!gates.passed) {
  for (const failure of gates.failures) console.error("GATE FAILURE: " + failure);
}
console.log("Full synthetic field-level metrics: .ci-logs/cv-parser-evaluation.json");
assert.deepEqual(gates.failures, [], "CV parser quality gates failed; inspect .ci-logs/cv-parser-evaluation.json");
console.log("CV PARSER EVALUATION PASSED: synthetic field-level gates met");
