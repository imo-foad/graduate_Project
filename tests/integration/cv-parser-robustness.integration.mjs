// CV parser robustness and security over the real disposable local HTTP stack (issue #24).
//
// Covers unsupported and mismatched content, malformed PDF/DOCX, empty documents, DTD/entity and
// zip-bomb DOCX structures, an encrypted PDF, the page limit, the bucket size limit, invalid metadata,
// path traversal in metadata, a foreign graduate, duplicate concurrent parsing, failure-state retries,
// unexpected Unicode and an external DOCX relationship. Every parsed document must leave suggestions
// PENDING and must not leak raw CV text in an error response.
//
// CV_PARSE is rate limited to five tokens per account, so disposable synthetic accounts are created
// with the local service role and no limit is relaxed or bypassed.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { buildDocx, buildDocxWithDocumentXml, buildPdf } from "../../scripts/cv-fixture-generator.mjs";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase CV robustness environment is incomplete");
const apiUrl = new URL(base);
assert.ok(apiUrl.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(apiUrl.hostname) &&
  apiUrl.port === "54321", "refusing CV robustness integration outside the disposable local Supabase API");

let passed = 0;
const pass = (name, condition, diagnostic) => {
  if (!condition && diagnostic !== undefined) {
    console.error("DIAGNOSTIC " + name + ": " + JSON.stringify(diagnostic, null, 2));
  }
  assert.equal(Boolean(condition), true, name);
  passed++;
  console.log("PASS " + name);
};
const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
async function readResponse(res) {
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* binary or empty */ }
  return { status: res.status, text, json };
}
async function request(path, init = {}) {
  return readResponse(await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) }));
}
async function login(email, credential = password) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password: credential }),
  });
  assert.equal(r.status, 200, "robustness account login failed: " + r.text);
  return { token: r.json.access_token, id: r.json.user.id, email };
}

const syntheticPrefix = "cv-robust-" + randomUUID().slice(0, 8);
const accounts = [];
const cleanupIssues = [];
const parsedDocuments = [];
async function newAccount() {
  const index = accounts.length;
  const email = `${syntheticPrefix}-${index}@alumni.test`;
  // The synthetic user gets its own password: the demo password belongs to the seeded accounts only.
  const credential = "Cv-Robust-" + randomUUID().slice(0, 12);
  const created = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password: credential, email_confirm: true }),
  });
  assert.ok(created.status === 200 || created.status === 201, "synthetic robustness account creation failed: " + created.text);
  const id = created.json?.id;
  assert.ok(typeof id === "string" && id.length > 0, "synthetic robustness account creation returned no user id");
  // Record the account before the password grant, so cleanup also deletes it if that login fails.
  const account = { id, email, token: null };
  accounts.push(account);
  const session = await login(email, credential);
  assert.equal(session.id, id, "robustness login resolved a different user than the one created");
  account.token = session.token;
  account.remaining = 5;
  return account;
}
const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");
async function uploadAndRegister(account, bytes, fileType, mime, options = {}) {
  const path = options.path ?? `${account.id}/cv-robust-${randomUUID()}.${fileType}`;
  const metadataPath = options.metadataPath ?? path;
  const up = await request("/storage/v1/object/cv-documents/" + encodePath(path), {
    method: "POST",
    headers: headers(account.token, { "Content-Type": mime, "x-upsert": "false" }),
    body: bytes,
  });
  if (options.expectUploadStatus) {
    return { upload: up, path };
  }
  assert.ok(up.status === 200 || up.status === 201, "robustness upload failed: " + up.text);
  const meta = await request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(account.token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({
      graduate_id: options.graduateId ?? account.id,
      storage_path: metadataPath,
      file_type: options.fileType ?? fileType,
      size_bytes: bytes.length,
    }),
  });
  assert.equal(meta.status, options.expectMetadataStatus ?? 201, "robustness metadata failed: " + meta.text);
  const id = meta.json?.[0]?.id;
  if (id) parsedDocuments.push({ id, account });
  return { upload: up, metadata: meta, id, path };
}
async function parse(account, id) {
  if (account.remaining !== undefined) account.remaining--;
  return request("/functions/v1/parse-cv", {
    method: "POST",
    headers: headers(account.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ cv_document_id: id }),
  });
}
async function documentState(account, id) {
  const row = await request("/rest/v1/cv_documents?select=parse_status,error_message&id=eq." + id, {
    headers: headers(account.token),
  });
  return row.json?.[0] ?? null;
}
async function expectRejected(account, bytes, fileType, mime, code, label) {
  const file = await uploadAndRegister(account, bytes, fileType, mime);
  const result = await parse(account, file.id);
  const state = await documentState(account, file.id);
  pass(label + " is rejected with " + code,
    result.status === 422 && result.json?.error === code &&
      state?.parse_status === "FAILED" && state?.error_message === code,
    { response: result.json ?? result.text, state });
  return { file, result, state };
}

function buildMinimalPdf(text) {
  return buildPdf([{ line: text }]);
}
function buildEncryptedPdf(text) {
  // A structurally valid PDF whose trailer advertises standard encryption. PDF.js must refuse it
  // instead of silently returning empty or partial text.
  const escaped = text.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
  const stream = `BT\n/F1 11 Tf\n72 720 Td\n(${escaped}) Tj\nET`;
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length " + Buffer.byteLength(stream, "latin1") + " >>\nstream\n" + stream + "\nendstream\nendobj\n",
    "6 0 obj\n<< /Filter /Standard /V 1 /R 2 /O <0000000000000000000000000000000000000000000000000000000000000000> /U <0000000000000000000000000000000000000000000000000000000000000000> /P -4 >>\nendobj\n",
  ];
  let output = "%PDF-1.4\n% Encrypted robustness fixture\n";
  const offsets = [0];
  for (const object of objects) { offsets.push(Buffer.byteLength(output, "latin1")); output += object; }
  const xref = Buffer.byteLength(output, "latin1");
  output += "xref\n0 " + (objects.length + 1) + "\n0000000000 65535 f \n";
  for (let index = 1; index < offsets.length; index++) {
    output += offsets[index].toString().padStart(10, "0") + " 00000 n \n";
  }
  output += "trailer\n<< /Size " + (objects.length + 1) + " /Root 1 0 R /Encrypt 6 0 R >>\nstartxref\n" + xref + "\n%%EOF\n";
  return Buffer.from(output, "latin1");
}
function buildManyPagePdf(pageCount) {
  const kids = Array.from({ length: pageCount }, (_, index) => `${index + 3} 0 R`).join(" ");
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    `2 0 obj\n<< /Type /Pages /Kids [${kids}] /Count ${pageCount} >>\nendobj\n`,
  ];
  for (let index = 0; index < pageCount; index++) {
    objects.push(`${index + 3} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n`);
  }
  let output = "%PDF-1.4\n% Page-limit robustness fixture\n";
  const offsets = [0];
  for (const object of objects) { offsets.push(Buffer.byteLength(output, "latin1")); output += object; }
  const xref = Buffer.byteLength(output, "latin1");
  output += "xref\n0 " + (objects.length + 1) + "\n0000000000 65535 f \n";
  for (let index = 1; index < offsets.length; index++) {
    output += offsets[index].toString().padStart(10, "0") + " 00000 n \n";
  }
  output += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(output, "latin1");
}
function wrapDocumentXml(inner) {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
    inner + "<w:sectPr/></w:body></w:document>";
}
const PDF_MIME = "application/pdf";
const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

try {
  const primary = await newAccount();
  const validPdf = buildMinimalPdf("Skills: Kotlin, Docker, SQL.");

  // ---- Content/extension mismatch and malformed containers ------------------------------------
  const mismatched = await uploadAndRegister(primary, buildDocx([{ line: "Skills: Kotlin" }]), "pdf", DOCX_MIME);
  const mismatchResult = await parse(primary, mismatched.id);
  const mismatchState = await documentState(primary, mismatched.id);
  pass("DOCX bytes declared as PDF are rejected as a type mismatch",
    mismatchResult.status === 422 && mismatchResult.json?.error === "CV_FILE_TYPE_MISMATCH" &&
    mismatchState?.parse_status === "FAILED", { response: mismatchResult.json, state: mismatchState });

  await expectRejected(primary, Buffer.from("%PDF-1.4\nnot a real document\n"), "pdf", PDF_MIME,
    "CV_INVALID_FILE", "malformed PDF");
  await expectRejected(primary, Buffer.concat([Buffer.from("PK\x03\x04"), Buffer.from(randomUUID())]), "docx", DOCX_MIME,
    "CV_INVALID_FILE", "corrupt DOCX/ZIP container");
  await expectRejected(primary, buildDocx([{ line: "" }]), "docx", DOCX_MIME,
    "CV_NO_TEXT_FOUND", "DOCX with no text");
  const hostileXml = '<!DOCTYPE w:document [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
    '<w:p><w:r><w:t>SECRET_MARKER_TEXT &xxe;</w:t></w:r></w:p></w:body></w:document>';
  const hostile = await expectRejected(primary, buildDocxWithDocumentXml(hostileXml), "docx", DOCX_MIME,
    "CV_INVALID_FILE", "DOCX declaring a DTD/entity");
  pass("a rejected hostile document does not echo CV text or entity content",
    !hostile.result.text.includes("SECRET_MARKER_TEXT") && !hostile.result.text.includes("passwd"), hostile.result.text);

  // ---- Bounded document limits (separate account: five CV_PARSE tokens per account) -----------
  const limitAccount = await newAccount();
  const oversizeXml = wrapDocumentXml("<w:p><w:r><w:t>" + "A".repeat(3 * 1024 * 1024) + "</w:t></w:r></w:p>");
  await expectRejected(limitAccount, buildDocxWithDocumentXml(oversizeXml), "docx", DOCX_MIME,
    "CV_INVALID_FILE", "DOCX with an oversized document.xml part");
  await expectRejected(limitAccount, buildManyPagePdf(41), "pdf", PDF_MIME,
    "CV_TOO_MANY_PAGES", "PDF above the 40-page limit");
  await expectRejected(limitAccount, buildEncryptedPdf("Kotlin and SQL"), "pdf", PDF_MIME,
    "CV_INVALID_FILE", "encrypted PDF");

  // ---- Storage and metadata limits ----------------------------------------------------------
  const tooLarge = Buffer.alloc(5 * 1024 * 1024 + 1, 0x41);
  const oversizedUpload = await uploadAndRegister(primary, tooLarge, "pdf", PDF_MIME, {
    expectUploadStatus: true,
  });
  pass("the private CV bucket rejects an oversized upload", [400, 413].includes(oversizedUpload.upload.status),
    oversizedUpload.upload.status);
  const invalidType = await uploadAndRegister(primary, validPdf, "pdf", PDF_MIME,
    { fileType: "txt", expectMetadataStatus: 400 });
  pass("invalid CV metadata file_type is rejected by the database", invalidType.metadata.status === 400,
    invalidType.metadata.text);

  const traversalAccount = await newAccount();
  const traversal = await uploadAndRegister(traversalAccount, validPdf, "pdf", PDF_MIME, {
    metadataPath: `${traversalAccount.id}/../${traversalAccount.id}/traversal.pdf`,
  });
  const traversalResult = await parse(traversalAccount, traversal.id);
  pass("metadata with a traversal storage_path is refused before any parse",
    traversalResult.status === 404 && traversalResult.json?.error === "CV_DOCUMENT_NOT_FOUND", traversalResult.json);

  // ---- Ownership and concurrency ------------------------------------------------------------
  const ownerAccount = await newAccount();
  const foreignAccount = await newAccount();
  const owned = await uploadAndRegister(ownerAccount, validPdf, "pdf", PDF_MIME);
  const foreign = await parse(foreignAccount, owned.id);
  pass("another graduate cannot parse the owner's CV", foreign.status === 404, foreign.json);
  pass("the foreign attempt did not consume the owner's document state",
    (await documentState(ownerAccount, owned.id))?.parse_status === "PENDING");

  const [first, second] = await Promise.all([parse(ownerAccount, owned.id), parse(ownerAccount, owned.id)]);
  const successes = [first, second].filter((result) => result.status === 200);
  const conflicts = [first, second].filter((result) => result.status === 409);
  pass("concurrent duplicate parsing allows exactly one worker",
    successes.length === 1 && conflicts.length === 1, { first: first.json, second: second.json });
  const suggestions = await request("/rest/v1/cv_suggestions?select=kind,payload,status&cv_document_id=eq." + owned.id, {
    headers: headers(ownerAccount.token),
  });
  const suggestionIds = new Set((suggestions.json ?? []).map((row) => row.payload?.skill_id));
  pass("concurrent parsing created one pending suggestion set",
    suggestions.status === 200 && suggestions.json?.length === 3 &&
    suggestions.json.every((row) => row.status === "PENDING") &&
    ["KOTLIN", "DOCKER", "SQL"].every((id) => suggestionIds.has(id)), suggestions.json);
  pass("a completed document cannot be parsed again", (await parse(ownerAccount, owned.id)).status === 409);

  // ---- Failure retry policy ------------------------------------------------------------------
  const retryAccount = await newAccount();
  const broken = await uploadAndRegister(retryAccount, Buffer.from("%PDF-1.4\nbroken\n"), "pdf", PDF_MIME);
  const firstFailure = await parse(retryAccount, broken.id);
  const secondFailure = await parse(retryAccount, broken.id);
  const failedState = await documentState(retryAccount, broken.id);
  pass("a FAILED document may be retried but stays FAILED with an accurate error",
    firstFailure.status === 422 && secondFailure.status === 422 &&
    failedState?.parse_status === "FAILED" && failedState?.error_message === "CV_INVALID_FILE",
    { first: firstFailure.json, second: secondFailure.json, state: failedState });

  // ---- Unexpected Unicode and external relationships ----------------------------------------
  const unicodeAccount = await newAccount();
  const unicodeDocx = buildDocx([
    { line: "السيرة الذاتية 🚀", heading: true },
    { line: "أعمل في تطوير البرمجيات باستخدام Kotlin وSQL." },
    { line: "Zero\u200bwidth\u200f and \u202eRTL\u202c markers." },
  ]);
  const unicodeFile = await uploadAndRegister(unicodeAccount, unicodeDocx, "docx", DOCX_MIME);
  const unicodeResult = await parse(unicodeAccount, unicodeFile.id);
  const unicodeSuggestions = await request("/rest/v1/cv_suggestions?select=payload,status&cv_document_id=eq." + unicodeFile.id, {
    headers: headers(unicodeAccount.token),
  });
  const unicodeIds = new Set((unicodeSuggestions.json ?? []).map((row) => row.payload?.skill_id));
  pass("unexpected Unicode content parses safely and keeps attached Arabic skills",
    unicodeResult.status === 200 && unicodeResult.json?.status === "DONE" &&
    unicodeIds.has("KOTLIN") && unicodeIds.has("SQL") &&
    unicodeSuggestions.json.every((row) => row.status === "PENDING"),
    { response: unicodeResult.json, suggestions: unicodeSuggestions.json });

  const externalRels = [["word/_rels/document.xml.rels",
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" ' +
    'Target="http://127.0.0.1:1/should-not-be-fetched" TargetMode="External"/></Relationships>']];
  const externalDocx = buildDocxWithDocumentXml(
    wrapDocumentXml('<w:p><w:r><w:t>Skills: Kotlin and Docker.</w:t></w:r></w:p>'),
    externalRels,
  );
  const externalFile = await uploadAndRegister(unicodeAccount, externalDocx, "docx", DOCX_MIME);
  const externalResult = await parse(unicodeAccount, externalFile.id);
  const externalSuggestions = await request("/rest/v1/cv_suggestions?select=payload&cv_document_id=eq." + externalFile.id, {
    headers: headers(unicodeAccount.token),
  });
  const externalIds = new Set((externalSuggestions.json ?? []).map((row) => row.payload?.skill_id));
  pass("an external DOCX relationship is not followed and does not affect extraction",
    externalResult.status === 200 && externalIds.has("KOTLIN") && externalIds.has("DOCKER") &&
    !JSON.stringify(externalSuggestions.json).includes("should-not-be-fetched"),
    { response: externalResult.json, suggestions: externalSuggestions.json });
} finally {
  for (const document of parsedDocuments) {
    await request("/rest/v1/rpc/delete_cv_document", {
      method: "POST",
      headers: headers(document.account.token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ p_cv_document_id: document.id }),
    }).catch(() => {});
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    const drained = await request("/functions/v1/cleanup-cv-objects", {
      method: "POST",
      headers: headers(service, { "Content-Type": "application/json" }),
      body: "{}",
    });
    if (drained.status !== 200 || (drained.json?.processed ?? 0) === 0) break;
  }
  for (const account of accounts) {
    const removed = await request("/auth/v1/admin/users/" + account.id, { method: "DELETE", headers: headers(service) }).catch(() => null);
    const after = await request("/auth/v1/admin/users/" + account.id, { headers: headers(service) }).catch(() => null);
    if (!after || after.status !== 404) {
      cleanupIssues.push(`${account.email}: delete=${removed?.status ?? "error"} read=${after?.status ?? "error"}`);
    }
  }
}

assert.deepEqual(cleanupIssues, [], "temporary robustness Auth users were not fully deleted: " + cleanupIssues.join("; "));
console.log("CV PARSER ROBUSTNESS INTEGRATION PASSED: " + passed + " checks");
