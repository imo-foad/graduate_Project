import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase CV integration environment is incomplete");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(base).hostname),
  "refusing to run against a non-local Supabase URL");

let passed = 0;
const pass = (name, condition) => {
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
  try { json = text ? JSON.parse(text) : null; } catch { /* response may be binary */ }
  return { status: res.status, ok: res.ok, text, json };
}
async function request(path, init = {}) {
  const res = await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) });
  return readResponse(res);
}
async function login(email) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password }),
  });
  pass("Auth password grant: " + email, r.status === 200 && Boolean(r.json?.access_token && r.json?.user?.id));
  return { token: r.json.access_token, id: r.json.user.id };
}
async function removeObject(token, path) {
  return request("/storage/v1/object/cv-documents", {
    method: "DELETE",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ prefixes: [path] }),
  });
}
function encodePath(path) {
  return path.split("/").map(encodeURIComponent).join("/");
}
function buildPdf(text) {
  const escaped = text.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
  const stream = "BT\n/F1 12 Tf\n50 750 Td\n(" + escaped + ") Tj\nET";
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length " + Buffer.byteLength(stream, "latin1") + " >>\nstream\n" + stream + "\nendstream\nendobj\n",
  ];
  let output = "%PDF-1.4\n% CV parser integration fixture\n";
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

const demoA = "graduate.demo@alumni.test";
const demoB = "graduate.android@alumni.test";
const a = await login(demoA);
const b = await login(demoB);
const pdfPath = a.id + "/cv-parser-" + randomUUID() + ".pdf";
const docxPath = b.id + "/cv-parser-" + randomUUID() + ".docx";
const blankPdfPath = a.id + "/cv-parser-blank-" + randomUUID() + ".pdf";
const pdf = buildPdf("Skills: Kotlin, JavaScript, React, Docker.");
const blankPdf = buildPdf("");
const docx = Buffer.from("UEsDBBQAAAAIAKSTeF3JTxqw6wAAAK4BAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH1QvU7DMBDeeQrLK4odGBBCSTrwMwJDeYCTfUks7LPlc0v79jht6YAK4933q69b7YIXW8zsIvXyRrVSIJloHU29/Fi/NPdScAGy4CNhL/fIcjVcdet9QhZVTNzLuZT0oDWbGQOwigmpImPMAUo986QTmE+YUN+27Z02kQpSacriIYfuCUfY+CKed/V9LJLRsxSPR+KS1UtIyTsDpeJ6S/ZXSnNKUFV54PDsEl9XgtQXExbk74CT7q0uk51F8Q65vEKoLP0Vs9U2mk2oSvW/zYWecRydwbN+cUs5GmSukwevzkgARz/99WHu4RtQSwMEFAAAAAgApJN4XbmBRHGwAAAAKgEAAAsAAABfcmVscy8ucmVsc43POw7CMAwG4J1TRN5pWgaEUJMuCKkrKgeIEjeNaB5KwqO3JwMDIAZG278/y233sDO5YUzGOwZNVQNBJ70yTjM4D8f1DkjKwikxe4cMFkzQ8VV7wlnkspMmExIpiEsMppzDntIkJ7QiVT6gK5PRRytyKaOmQciL0Eg3db2l8d0A/mGSXjGIvWqADEvAf2w/jkbiwcurRZd/nPhKFFlEjZnB3UdF1atdFRYob+nHi/wJUEsDBBQAAAAIAKSTeF2Z6QuA1AAAAD4BAAARAAAAd29yZC9kb2N1bWVudC54bWxtj8FKBDEMhu8+Rejd6ehBZJiZBVn27EEfoLZxp2yblDbj7Ly97YII4uUPIeTLl/FwjQG+MBfPNKmHrleAZNl5Ok/q/e10/6ygiCFnAhNOaseiDvPduA2O7RqRBCqByrBNahFJg9bFLhhN6Tgh1dkn52iktvmsN84uZbZYSj0Qg37s+ycdjSc1V+QHu73V1CK3kPl1l4UJqgEc2V4wA14TZl8tETyBLAg28OpA0MRu1G2pZb5l+st7WX0QSD5h8ITlBjarcHXExihV9R+I/rHTv5/P31BLAQIUAxQAAAAIAKSTeF3JTxqw6wAAAK4BAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgApJN4XbmBRHGwAAAAKgEAAAsAAAAAAAAAAAAAAIABHAEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAgApJN4XZnpC4DUAAAAPgEAABEAAAAAAAAAAAAAAIAB9QEAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAADAAMAuQAAAPgCAAAAAA==", "base64");let pdfId = null;
let docxId = null;
let blankPdfId = null;

async function upload(path, token, bytes, mime) {
  return request("/storage/v1/object/cv-documents/" + encodePath(path), {
    method: "POST",
    headers: headers(token, { "Content-Type": mime, "x-upsert": "false" }),
    body: bytes,
  });
}
async function createMetadata(token, uid, path, type, bytes) {
  return request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({ graduate_id: uid, storage_path: path, file_type: type, size_bytes: bytes.length }),
  });
}
async function parse(token, id) {
  return request("/functions/v1/parse-cv", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ cv_document_id: id }),
  });
}

try {
  const getMethod = await request("/functions/v1/parse-cv", { method: "GET", headers: headers(a.token) });
  pass("parse-cv rejects non-POST methods", getMethod.status === 405);
  const noAuth = await request("/functions/v1/parse-cv", {
    method: "POST", headers: headers(null, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("parse-cv rejects missing JWT", noAuth.status === 401);
  const invalidAuth = await request("/functions/v1/parse-cv", {
    method: "POST", headers: headers("invalid.jwt.token", { "Content-Type": "application/json" }), body: "{}",
  });
  pass("parse-cv rejects invalid JWT", invalidAuth.status === 401);
  const invalidBody = await request("/functions/v1/parse-cv", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }), body: "{}",
  });
  pass("parse-cv validates request body", invalidBody.status === 400);

  const pdfUpload = await upload(pdfPath, a.token, pdf, "application/pdf");
  pass("graduate uploads a structurally valid PDF", pdfUpload.status === 200 || pdfUpload.status === 201);
  const pdfMetadata = await createMetadata(a.token, a.id, pdfPath, "pdf", pdf);
  pass("graduate registers PDF metadata", pdfMetadata.status === 201 && pdfMetadata.json?.length === 1);
  pdfId = pdfMetadata.json?.[0]?.id ?? null;

  const foreignAccess = await parse(b.token, pdfId);
  pass("another graduate cannot parse this PDF", foreignAccess.status === 404);

  const simultaneous = await Promise.all([parse(a.token, pdfId), parse(a.token, pdfId)]);
  const successfulParses = simultaneous.filter((result) => result.status === 200);
  const blockedParses = simultaneous.filter((result) => result.status === 409);
  pass("simultaneous parse requests allow exactly one processor", successfulParses.length === 1 &&
    blockedParses.length === 1);
  const parsedPdf = successfulParses[0];
  pass("PDF parsing extracts four dictionary skills", parsedPdf?.json?.status === "DONE" &&
    parsedPdf?.json?.suggestions_count === 4 && parsedPdf?.json?.confirmation_required === true);

  const pdfSuggestions = await request("/rest/v1/cv_suggestions?select=id,payload,status&cv_document_id=eq." + pdfId, {
    headers: headers(a.token),
  });
  const pdfSkillIds = new Set((pdfSuggestions.json ?? []).map((row) => row.payload?.skill_id));
  pass("PDF suggestions are saved pending graduate review", pdfSuggestions.status === 200 &&
    pdfSuggestions.json?.length === 4 && pdfSuggestions.json.every((row) => row.status === "PENDING") &&
    ["KOTLIN", "JAVASCRIPT", "REACT", "DOCKER"].every((id) => pdfSkillIds.has(id)));

  const beforeConfirm = await request("/rest/v1/graduate_skills?select=skill_id,source&source=eq.CV_CONFIRMED", {
    headers: headers(a.token),
  });
  pass("no skills are added before explicit confirmation", beforeConfirm.status === 200 && beforeConfirm.json?.length === 0);

  const accepted = (pdfSuggestions.json ?? [])
    .filter((row) => ["KOTLIN", "JAVASCRIPT"].includes(row.payload?.skill_id)).map((row) => row.id);
  const rejected = (pdfSuggestions.json ?? [])
    .filter((row) => ["REACT", "DOCKER"].includes(row.payload?.skill_id)).map((row) => row.id);
  const confirmation = await request("/rest/v1/rpc/confirm_cv_suggestions", {
    method: "POST", headers: headers(a.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_confirm: accepted, p_reject: rejected }),
  });
  pass("graduate can confirm and reject CV suggestions", confirmation.status === 200 &&
    confirmation.json?.confirmed === 2 && confirmation.json?.rejected === 2);

  const confirmedRows = await request("/rest/v1/graduate_skills?select=skill_id,source&source=eq.CV_CONFIRMED", {
    headers: headers(a.token),
  });
  const confirmedIds = new Set((confirmedRows.json ?? []).map((row) => row.skill_id));
  pass("only approved skills enter graduate_skills", confirmedRows.status === 200 &&
    confirmedIds.has("KOTLIN") && confirmedIds.has("JAVASCRIPT") &&
    !confirmedIds.has("REACT") && !confirmedIds.has("DOCKER"));

  const duplicateParse = await parse(a.token, pdfId);
  pass("completed PDF cannot be parsed again", duplicateParse.status === 409 &&
    duplicateParse.json?.error === "CV_ALREADY_PARSED");

  const docxUpload = await upload(docxPath, b.token, docx,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
  pass("graduate uploads a real DOCX file", docxUpload.status === 200 || docxUpload.status === 201);
  const docxMetadata = await createMetadata(b.token, b.id, docxPath, "docx", docx);
  pass("graduate registers DOCX metadata", docxMetadata.status === 201 && docxMetadata.json?.length === 1);
  docxId = docxMetadata.json?.[0]?.id ?? null;
  const parsedDocx = await parse(b.token, docxId);
  const docxSuggestions = await request("/rest/v1/cv_suggestions?select=payload,status&cv_document_id=eq." + docxId, {
    headers: headers(b.token),
  });
  const docxSkillIds = new Set((docxSuggestions.json ?? []).map((row) => row.payload?.skill_id));
  pass("DOCX parsing extracts Python and Docker skills", parsedDocx.status === 200 &&
    parsedDocx.json?.status === "DONE" && docxSuggestions.status === 200 &&
    docxSkillIds.has("PYTHON") && docxSkillIds.has("DOCKER") &&
    docxSuggestions.json.every((row) => row.status === "PENDING"));

  const blankUpload = await upload(blankPdfPath, a.token, blankPdf, "application/pdf");
  pass("graduate uploads a text-empty PDF fixture", blankUpload.status === 200 || blankUpload.status === 201);
  const blankMetadata = await createMetadata(a.token, a.id, blankPdfPath, "pdf", blankPdf);
  pass("graduate registers text-empty PDF metadata", blankMetadata.status === 201 && blankMetadata.json?.length === 1);
  blankPdfId = blankMetadata.json?.[0]?.id ?? null;
  const blankResult = await parse(a.token, blankPdfId);
  const blankStatus = await request("/rest/v1/cv_documents?select=parse_status,error_message&id=eq." + blankPdfId, {
    headers: headers(a.token),
  });
  pass("text-empty PDF is rejected and document becomes FAILED", blankResult.status === 422 &&
    blankResult.json?.error === "CV_NO_TEXT_FOUND" &&
    blankStatus.json?.[0]?.parse_status === "FAILED" &&
    blankStatus.json?.[0]?.error_message === "CV_NO_TEXT_FOUND");

  const otherSuggestions = await request("/rest/v1/cv_suggestions?select=id&cv_document_id=eq." + pdfId, {
    headers: headers(b.token),
  });
  pass("another graduate cannot read PDF suggestions", otherSuggestions.status === 200 && otherSuggestions.json?.length === 0);
} finally {
  await removeObject(service, pdfPath).catch(() => {});
  await removeObject(service, docxPath).catch(() => {});
  await removeObject(service, blankPdfPath).catch(() => {});
  for (const id of [pdfId, docxId, blankPdfId]) {
    if (id) await request("/rest/v1/cv_documents?id=eq." + id, {
      method: "DELETE", headers: headers(service),
    }).catch(() => {});
  }
}
console.log("CV PARSING INTEGRATION PASSED: " + passed + " checks");
