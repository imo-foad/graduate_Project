// End-to-end CV Storage cleanup (issue #18) against the disposable LOCAL Supabase stack only.
//
// Proves the durable queue against REAL private Storage objects: owner deletion, replacement under
// a fresh key, permanent retired-path rejection, an already-missing object, a rejected unsafe path, scheduled retry after a
// recorded failure, an expired worker lease, concurrent claims, exhausted attempts with the operator
// requeue, the full approved account-deletion lifecycle, and worker/queue authorization.
//
// The database target is validated as localhost before the first psql call, and the Supabase API URL
// must be a localhost origin on port 54321. No Cloud project, credential or object is used.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { assertLocalDbUrl } from "../../scripts/assert-local-db.mjs";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase CV cleanup environment is incomplete");
const apiUrl = new URL(base);
assert.ok(apiUrl.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(apiUrl.hostname) &&
  apiUrl.port === "54321", "refusing CV cleanup integration outside the disposable local Supabase API");

const DB_URL = process.env.DB_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
assertLocalDbUrl(DB_URL); // throws for any non-local target

let passed = 0;
const pass = (name, condition, diagnostic) => {
  if (!condition && diagnostic !== undefined) {
    console.error("DIAGNOSTIC " + name + ": " + JSON.stringify(diagnostic, null, 2));
  }
  assert.equal(Boolean(condition), true, name);
  passed++;
  console.log("PASS " + name);
};
function sql(statement) {
  return execFileSync("psql", ["-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", DB_URL, "-c", statement], {
    encoding: "utf8",
  }).trim();
}
const sqlInt = (statement) => Number(sql(statement) || "0");

const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
async function readResponse(res) {
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* binary or empty */ }
  return { status: res.status, ok: res.ok, text, json };
}
async function request(path, init = {}) {
  const res = await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) });
  return readResponse(res);
}
async function login(email, accountPassword = password) {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password: accountPassword }),
  });
  const summary = {
    status: r.status,
    error: r.json?.error_description ?? r.json?.error ?? r.json?.msg ?? r.json?.message ?? null,
  };
  pass("Auth password grant: " + email, r.status === 200 && Boolean(r.json?.access_token && r.json?.user?.id), summary);
  return { token: r.json.access_token, id: r.json.user.id };
}
const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");
const uploadPath = (path) => "/storage/v1/object/cv-documents/" + encodePath(path);
const downloadPath = (path) => "/storage/v1/object/cv-documents/" + encodePath(path);
async function upload(token, path, bytes) {
  return request(uploadPath(path), {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/pdf", "x-upsert": "false" }),
    body: bytes,
  });
}
async function removeObject(token, path) {
  return request(downloadPath(path), { method: "DELETE", headers: headers(token) });
}
async function download(token, path) {
  const res = await fetch(base + downloadPath(path), {
    headers: headers(token),
    signal: AbortSignal.timeout(60_000),
  });
  const body = Buffer.from(await res.arrayBuffer());
  return { status: res.status, bytes: body, text: body.toString("latin1") };
}
async function createMetadata(token, uid, path, bytes) {
  return request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({ graduate_id: uid, storage_path: path, file_type: "pdf", size_bytes: bytes.length }),
  });
}
async function deleteMetadata(token, id) {
  return request("/rest/v1/rpc/delete_cv_document", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_cv_document_id: id }),
  });
}
async function worker(token = service) {
  return request("/functions/v1/cleanup-cv-objects", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: "{}",
  });
}
async function serviceRpc(fn, body) {
  return request("/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json" }),
    body: JSON.stringify(body),
  });
}
const queueRows = (path) => sql(
  "select coalesce(json_agg(json_build_object('status', status, 'attempts', attempts, " +
  "'last_error', last_error, 'next_attempt_at', next_attempt_at) order by created_at), '[]'::json) " +
  "from private.cv_cleanup_queue where storage_path = " + quote(path),
);
const queue = (path) => JSON.parse(queueRows(path));
const queueCount = (path) => queue(path).length;
function quote(value) {
  return "'" + String(value).replace(/'/g, "''") + "'";
}
const metadataCount = (id) => sqlInt("select count(*) from public.cv_documents where id = " + quote(id));
const queueTotal = () => sqlInt("select count(*) from private.cv_cleanup_queue");

function escapePdfLiteral(value) {
  return value.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
}
function buildPdf(text) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const commands = lines.map((line, index) => (index === 0 ? "" : "T*\n") + "(" + escapePdfLiteral(line) + ") Tj").join("\n");
  const stream = ["BT", "/F1 11 Tf", "13 TL", "45 750 Td", commands, "ET"].join("\n");
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length " + Buffer.byteLength(stream, "latin1") + " >>\nstream\n" + stream + "\nendstream\nendobj\n",
  ];
  let output = "%PDF-1.4\n% Synthetic CV cleanup fixture\n";
  const offsets = [0];
  for (const object of objects) { offsets.push(Buffer.byteLength(output, "latin1")); output += object; }
  const xref = Buffer.byteLength(output, "latin1");
  output += "xref\n0 6\n0000000000 65535 f \n";
  for (let i = 1; i < offsets.length; i++) output += offsets[i].toString().padStart(10, "0") + " 00000 n \n";
  output += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" + xref + "\n%%EOF\n";
  return Buffer.from(output, "latin1");
}

const createdUsers = [];
const staleObjects = [];
let insertedAdminId = null;
const owner = await login("graduate.demo@alumni.test");
const other = await login("graduate.android@alumni.test");
const tag = randomUUID();
const ownerPrefix = owner.id + "/cleanup-e2e-" + tag;

// Start from a drained ledger so per-scenario assertions cannot be inflated by earlier suites.
const backlog = await worker();
pass("pre-test worker drains earlier cleanup backlog", backlog.status === 200, backlog.json ?? backlog.text);
pass("pre-test backlog contains no unresolved Storage failures", backlog.json?.failed === 0, backlog.json);

try {
  // ---- A. Owner deletion removes the real Storage bytes -------------------------------------------
  const pathA = ownerPrefix + "-owner.pdf";
  const bytesA = buildPdf("WORK EXPERIENCE\nCleanup Owner | Storage Labs\n2020 - 2021\nPDF body");
  staleObjects.push(pathA);
  const upA = await upload(owner.token, pathA, bytesA);
  pass("owner uploads a real private PDF object", upA.status === 200 || upA.status === 201, upA);
  const downA = await download(owner.token, pathA);
  pass("owner can download the object before deletion", downA.status === 200 && downA.text.length > 0, downA.status);
  const metaA = await createMetadata(owner.token, owner.id, pathA, bytesA);
  pass("owner registers CV metadata for the object", metaA.status === 201 && metaA.json?.length === 1, metaA);
  const idA = metaA.json?.[0]?.id;
  const foreignDelete = await deleteMetadata(other.token, idA);
  pass("another graduate cannot delete the owner's CV metadata", foreignDelete.status === 404, foreignDelete);

  const deleteA = await deleteMetadata(owner.token, idA);
  pass("owner deletes CV metadata through the owner RPC", deleteA.status === 200 && deleteA.json?.deleted === true, deleteA);
  pass("CV metadata row is gone", metadataCount(idA) === 0);
  const queuedA = queue(pathA);
  pass("exactly one cleanup row is enqueued for the deleted object",
    queuedA.length === 1 && queuedA[0].status === "PENDING", queuedA);
  // A second delete of the same document must not duplicate queue work.
  const secondDelete = await deleteMetadata(owner.token, idA);
  pass("repeating the metadata deletion is rejected without duplicating cleanup",
    secondDelete.status === 404 && queueCount(pathA) === 1, secondDelete);

  const drainedA = await worker();
  pass("worker drains the queued object", drainedA.status === 200 && (drainedA.json?.done ?? 0) >= 1 &&
    drainedA.json?.failed === 0, drainedA.json);
  const doneA = queue(pathA);
  pass("the queue row reaches DONE", doneA.length === 1 && doneA[0].status === "DONE" && doneA[0].attempts === 1, doneA);
  const afterDelete = await download(owner.token, pathA);
  pass("the deleted object is no longer downloadable", afterDelete.status !== 200, afterDelete.status);
  const foreignAfter = await download(other.token, pathA);
  pass("an unrelated graduate cannot read the deleted object", foreignAfter.status !== 200, foreignAfter.status);

  // ---- B. Replacement: only the old object is removed ---------------------------------------------
  const oldPath = ownerPrefix + "-replace-old.pdf";
  const newPath = ownerPrefix + "-replace-new.pdf";
  const oldBytes = buildPdf("OLD REPLACED CV\nKotlin");
  const newBytes = buildPdf("NEW ACTIVE CV\nPython and SQL");
  staleObjects.push(oldPath, newPath);
  pass("old replacement object uploads", (await upload(owner.token, oldPath, oldBytes)).status < 300);
  pass("new replacement object uploads", (await upload(owner.token, newPath, newBytes)).status < 300);
  const oldMeta = await createMetadata(owner.token, owner.id, oldPath, oldBytes);
  const newMeta = await createMetadata(owner.token, owner.id, newPath, newBytes);
  pass("both replacement metadata rows exist",
    oldMeta.status === 201 && newMeta.status === 201 && oldMeta.json?.[0]?.id !== newMeta.json?.[0]?.id);
  const newId = newMeta.json?.[0]?.id;
  // Supported application flow: register the new document, then delete the superseded metadata row.
  const replaceDelete = await deleteMetadata(owner.token, oldMeta.json?.[0]?.id);
  pass("the superseded CV is deleted through the owner RPC", replaceDelete.status === 200, replaceDelete);
  pass("cleanup is queued for the old path only",
    queueCount(oldPath) === 1 && queueCount(newPath) === 0, { old: queue(oldPath), new: queue(newPath) });
  const replaceDrain = await worker();
  pass("worker completes the replacement cleanup", replaceDrain.status === 200 && replaceDrain.json?.failed === 0, replaceDrain.json);
  pass("the old object is gone", (await download(owner.token, oldPath)).status !== 200);
  const newDownload = await download(owner.token, newPath);
  pass("the new object remains downloadable", newDownload.status === 200, newDownload.status);
  pass("the new object's bytes are unchanged", Buffer.compare(newDownload.bytes, newBytes) === 0);
  pass("metadata still points at the new path", metadataCount(newId) === 1 &&
    sql("select storage_path from public.cv_documents where id = " + quote(newId)) === newPath);
  pass("no cleanup row was ever created for the new path", queueCount(newPath) === 0);

  // ---- B2. Immutable Storage paths: a retired key is rejected in every queue state ----------------
  const retiredPath = ownerPrefix + "-retired.pdf";
  const retiredBytes = buildPdf("RETIRED CV\nReact");
  staleObjects.push(retiredPath);
  const retiredUpload = await upload(owner.token, retiredPath, retiredBytes);
  pass("the original private object uploads before retirement",
    retiredUpload.status === 200 || retiredUpload.status === 201, retiredUpload.status);
  const retiredMeta = await createMetadata(owner.token, owner.id, retiredPath, retiredBytes);
  const retiredId = retiredMeta.json?.[0]?.id;
  pass("metadata is registered for the original Storage object",
    retiredMeta.status === 201 && Boolean(retiredId), retiredMeta);
  const retireResult = await deleteMetadata(owner.token, retiredId);
  pass("metadata deletion queues the Storage path through the owner RPC",
    retireResult.status === 200 && queueCount(retiredPath) === 1 &&
    queue(retiredPath)[0]?.status === "PENDING", { response: retireResult, rows: queue(retiredPath) });
  pass("no live metadata references a queued path",
    sqlInt("select count(*) from public.cv_documents d join private.cv_cleanup_queue q on q.storage_path = d.storage_path where q.storage_path = " + quote(retiredPath)) === 0);

  const retiredRegistration = await createMetadata(owner.token, owner.id, retiredPath, retiredBytes);
  pass("a PENDING cleanup path is rejected as permanently retired",
    retiredRegistration.status >= 400 && retiredRegistration.json?.message === "CV_STORAGE_PATH_RETIRED",
    { status: retiredRegistration.status, error: retiredRegistration.json?.message ?? retiredRegistration.text });

  const retiredDrain = await worker();
  const retiredRows = queue(retiredPath);
  pass("the real worker deletes the retired object bytes",
    retiredDrain.status === 200 && retiredRows.length === 1 && retiredRows[0]?.status === "DONE" &&
    (await download(owner.token, retiredPath)).status !== 200,
    { response: retiredDrain.json, rows: retiredRows });

  const freshPath = ownerPrefix + "-fresh-replacement.pdf";
  const freshBytes = buildPdf("FRESH REPLACEMENT CV\nPython and SQL");
  staleObjects.push(freshPath);
  const freshUpload = await upload(owner.token, freshPath, freshBytes);
  pass("a replacement CV uploads under a different fresh path",
    freshUpload.status === 200 || freshUpload.status === 201, freshUpload.status);
  const freshMeta = await createMetadata(owner.token, owner.id, freshPath, freshBytes);
  const freshId = freshMeta.json?.[0]?.id;
  pass("a never-used replacement path registers successfully",
    freshMeta.status === 201 && Boolean(freshId), freshMeta);
  const afterFreshRegistration = await worker();
  const freshDownload = await download(owner.token, freshPath);
  pass("running cleanup for the old tombstone cannot delete the new object",
    afterFreshRegistration.status === 200 && freshDownload.status === 200 &&
    Buffer.compare(freshDownload.bytes, freshBytes) === 0 &&
    metadataCount(freshId) === 1 &&
    sql("select storage_path from public.cv_documents where id = " + quote(freshId)) === freshPath,
    { response: afterFreshRegistration.json, downloadStatus: freshDownload.status });
  pass("the old retired path remains a single DONE tombstone",
    queue(retiredPath).length === 1 && queue(retiredPath)[0]?.status === "DONE");
  pass("the new path has no cleanup entry",
    queueCount(freshPath) === 0 &&
    sqlInt("select count(*) from public.cv_documents d join private.cv_cleanup_queue q on q.storage_path = d.storage_path") === 0);

  // ---- C. Already-missing object is idempotent ----------------------------------------------------
  const missingPath = ownerPrefix + "-missing.pdf";
  const missingBytes = buildPdf("NEVER UPLOADED");
  const missingMeta = await createMetadata(owner.token, owner.id, missingPath, missingBytes);
  await deleteMetadata(owner.token, missingMeta.json?.[0]?.id);
  const missingDrain = await worker();
  pass("a queued path without an object still completes", missingDrain.status === 200 && missingDrain.json?.failed === 0, missingDrain.json);
  const missingQueue = queue(missingPath);
  pass("missing-object cleanup reaches DONE once", missingQueue.length === 1 && missingQueue[0].status === "DONE", missingQueue);
  const missingAgain = await worker();
  pass("re-running the worker does not duplicate or corrupt missing-object state",
    missingAgain.status === 200 && queue(missingPath).length === 1 && queue(missingPath)[0].status === "DONE", missingAgain.json);

  // ---- D. Failure recording, unsafe paths, and scheduled retry ------------------------------------
  const sentinelPath = other.id + "/cleanup-e2e-sentinel-" + tag + ".pdf";
  staleObjects.push(sentinelPath);
  const sentinelBytes = buildPdf("UNRELATED GRADUATE CV");
  pass("an unrelated sentinel object exists", (await upload(other.token, sentinelPath, sentinelBytes)).status < 300);

  const unsafePath = "../../other-user/steal.pdf";
  sql("insert into private.cv_cleanup_queue (storage_path, graduate_id, reason) values (" +
    quote(unsafePath) + ", " + quote(owner.id) + ", 'METADATA_DELETE')");
  const unsafeDrain = await worker();
  const unsafeRows = queue(unsafePath);
  pass("the worker records a rejected unsafe Storage path",
    unsafeDrain.status === 200 && (unsafeDrain.json?.failed ?? 0) >= 1 &&
    unsafeRows.length === 1 && unsafeRows[0].status === "FAILED" &&
    unsafeRows[0].last_error === "UNSAFE_STORAGE_PATH" && unsafeRows[0].attempts === 1,
    { response: unsafeDrain.json, rows: unsafeRows });
  pass("the unrelated graduate's object is untouched by an unsafe cleanup path",
    (await download(other.token, sentinelPath)).status === 200);
  sql("delete from private.cv_cleanup_queue where storage_path = " + quote(unsafePath));

  const retryPath = ownerPrefix + "-retry.pdf";
  const retryBytes = buildPdf("RETRY CV\nDocker");
  staleObjects.push(retryPath);
  pass("retry fixture object uploads", (await upload(owner.token, retryPath, retryBytes)).status < 300);
  sql("insert into private.cv_cleanup_queue (storage_path, graduate_id, reason, status, attempts, last_error, next_attempt_at) values (" +
    quote(retryPath) + ", " + quote(owner.id) + ", 'METADATA_DELETE', 'FAILED', 1, 'STORAGE_DELETE_FAILED', now() + interval '5 minutes')");
  const scheduledDrain = await worker();
  const scheduledQueue = queue(retryPath);
  pass("a failed cleanup is not retried before its scheduled attempt",
    scheduledDrain.status === 200 && scheduledQueue[0]?.status === "FAILED" &&
    (await download(owner.token, retryPath)).status === 200, { response: scheduledDrain.json, rows: scheduledQueue });
  sql("update private.cv_cleanup_queue set next_attempt_at = now() - interval '1 second' where storage_path = " + quote(retryPath));
  const retriedDrain = await worker();
  const retriedQueue = queue(retryPath);
  pass("the retry deletes the original object once its schedule is due",
    retriedDrain.status === 200 && retriedQueue[0]?.status === "DONE" && retriedQueue[0]?.attempts === 2 &&
    (await download(owner.token, retryPath)).status !== 200, { response: retriedDrain.json, rows: retriedQueue });
  pass("the reconciliation report is service-role readable and has no failed backlog",
    (await serviceRpc("get_cv_cleanup_report", {})).json?.failed === 0, (await serviceRpc("get_cv_cleanup_report", {})).json);

  // ---- E. Expired lease recovery and concurrent claims ---------------------------------------------
  const leasePath = ownerPrefix + "-lease.pdf";
  const leaseBytes = buildPdf("LEASE CV\nKotlin");
  staleObjects.push(leasePath);
  pass("lease fixture object uploads", (await upload(owner.token, leasePath, leaseBytes)).status < 300);
  sql("insert into private.cv_cleanup_queue (storage_path, graduate_id, reason) values (" +
    quote(leasePath) + ", " + quote(owner.id) + ", 'METADATA_DELETE')");
  const leaseId = sql("select id from private.cv_cleanup_queue where storage_path = " + quote(leasePath));
  const [claimOne, claimTwo] = await Promise.all([
    serviceRpc("claim_cv_cleanup", { p_limit: 20 }),
    serviceRpc("claim_cv_cleanup", { p_limit: 20 }),
  ]);
  const claimedIds = [...(claimOne.json ?? []), ...(claimTwo.json ?? [])].map((row) => row.id);
  pass("two concurrent workers claim the leased row exactly once",
    claimOne.status === 200 && claimTwo.status === 200 &&
    claimedIds.filter((id) => id === leaseId).length === 1, { one: claimOne.json, two: claimTwo.json });
  const leased = queue(leasePath)[0];
  pass("a claimed row is PROCESSING with one counted attempt", leased?.status === "PROCESSING" && leased?.attempts === 1, leased);
  sql("update private.cv_cleanup_queue set claimed_at = now() - interval '16 minutes' where id = " + quote(leaseId));
  const reclaimed = await serviceRpc("claim_cv_cleanup", { p_limit: 20 });
  const reclaimedRow = (reclaimed.json ?? []).find((row) => row.id === leaseId);
  pass("an expired lease is recovered and re-claimed",
    Boolean(reclaimedRow) && queue(leasePath)[0]?.attempts === 2, { reclaimed: reclaimed.json, rows: queue(leasePath) });
  const completeOnce = await serviceRpc("complete_cv_cleanup", { p_id: leaseId });
  const completeTwice = await serviceRpc("complete_cv_cleanup", { p_id: leaseId });
  pass("completion is idempotent", completeOnce.json === true && completeTwice.json === false,
    { first: completeOnce.json, second: completeTwice.json });
  const failAfterComplete = await serviceRpc("fail_cv_cleanup", { p_id: leaseId, p_error: "late" });
  pass("a late failure cannot regress a DONE row", failAfterComplete.json === false && queue(leasePath)[0]?.status === "DONE");
  pass("the lease fixture object was not deleted by claim/complete alone",
    (await download(owner.token, leasePath)).status === 200);

  // ---- F. Exhausted attempts and the service-role operator retry -----------------------------------
  const exhaustedPath = ownerPrefix + "-exhausted.pdf";
  const exhaustedBytes = buildPdf("EXHAUSTED CV\nTableau");
  staleObjects.push(exhaustedPath);
  pass("exhausted fixture object uploads", (await upload(owner.token, exhaustedPath, exhaustedBytes)).status < 300);
  sql("insert into private.cv_cleanup_queue (storage_path, graduate_id, reason, status, attempts, last_error, next_attempt_at) values (" +
    quote(exhaustedPath) + ", " + quote(owner.id) + ", 'METADATA_DELETE', 'FAILED', 10, 'STORAGE_DELETE_FAILED', now())");
  const exhaustedId = sql("select id from private.cv_cleanup_queue where storage_path = " + quote(exhaustedPath));
  const exhaustedDrain = await worker();
  const exhaustedQueue = queue(exhaustedPath);
  pass("an exhausted row is never claimed automatically",
    exhaustedDrain.status === 200 && exhaustedQueue[0]?.status === "FAILED" && exhaustedQueue[0]?.attempts === 10 &&
    (await download(owner.token, exhaustedPath)).status === 200, { response: exhaustedDrain.json, rows: exhaustedQueue });
  const report = await serviceRpc("get_cv_cleanup_report", {});
  pass("the report exposes the exhausted row", report.status === 200 && (report.json?.exhausted ?? 0) >= 1, report.json);

  const userRetry = await request("/rest/v1/rpc/retry_cv_cleanup", {
    method: "POST",
    headers: headers(owner.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_id: exhaustedId }),
  });
  pass("an authenticated client cannot requeue exhausted cleanup work", userRetry.status >= 400, userRetry);
  const operatorRetry = await serviceRpc("retry_cv_cleanup", { p_id: exhaustedId });
  pass("the service-role operator requeues the exhausted row", operatorRetry.status === 200 && operatorRetry.json === true,
    operatorRetry);
  const recoveredDrain = await worker();
  const recoveredQueue = queue(exhaustedPath);
  pass("the operator-retried row is deleted and reaches DONE",
    recoveredDrain.status === 200 && recoveredQueue[0]?.status === "DONE" &&
    (await download(owner.token, exhaustedPath)).status !== 200,
    { response: recoveredDrain.json, rows: recoveredQueue });

  // ---- G. Approved account deletion cleans every object --------------------------------------------
  const email = "cv-cleanup-e2e-" + tag + "@alumni.test";
  const targetPassword = "Cv-Cleanup-Test-" + tag.slice(0, 8);
  const created = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: headers(service, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password: targetPassword, email_confirm: true }),
  });
  pass("service role creates a disposable local Auth account", created.status === 200 || created.status === 201, {
    status: created.status,
    error: created.json?.error_description ?? created.json?.error ?? created.json?.msg ?? created.json?.message ?? null,
    hasId: Boolean(created.json?.id),
  });
  const targetId = created.json?.id;
  createdUsers.push(targetId);
  const target = await login(email, targetPassword);
  const accountPaths = [
    targetId + "/account-a-" + tag + ".pdf",
    targetId + "/account-b-" + tag + ".pdf",
  ];
  staleObjects.push(...accountPaths);
  for (const [index, path] of accountPaths.entries()) {
    const bytes = buildPdf("ACCOUNT DELETION CV " + index + "\nSQL and Python");
    pass("account-deletion CV " + (index + 1) + " uploads", (await upload(target.token, path, bytes)).status < 300);
    const meta = await createMetadata(target.token, targetId, path, bytes);
    pass("account-deletion CV " + (index + 1) + " metadata exists", meta.status === 201 && meta.json?.length === 1, meta);
  }
  const requested = await request("/rest/v1/rpc/request_account_deletion", {
    method: "POST",
    headers: headers(target.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_reason: "synthetic local cleanup verification" }),
  });
  pass("the owner can request account deletion", requested.status === 200 && typeof requested.json === "string", requested);

  // Provision a disposable local platform admin only for this scenario's approval step.
  insertedAdminId = sql(
    "with inserted as (" +
    " insert into private.platform_admins (user_id) " +
    " select id from public.profiles where email = 'graduate.data@alumni.test' " +
    " on conflict (user_id) do nothing returning user_id) select coalesce(user_id::text, '') from inserted",
  ) || null;
  const admin = await login("graduate.data@alumni.test");
  const approved = await request("/rest/v1/rpc/review_account_deletion_request", {
    method: "POST",
    headers: headers(admin.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_request_id: requested.json, p_decision: "APPROVE", p_note: "local synthetic cleanup test" }),
  });
  pass("the platform admin approves the account deletion", approved.status === 200 && approved.json === "APPROVED", approved);
  const deleted = await request("/functions/v1/delete-graduate", {
    method: "POST",
    headers: headers(admin.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ request_id: requested.json }),
  });
  pass("delete-graduate completes the supported account lifecycle",
    deleted.status === 200 && deleted.json?.status === "COMPLETED", deleted);
  pass("all account CV metadata is deleted",
    sqlInt("select count(*) from public.cv_documents where graduate_id = " + quote(targetId)) === 0);
  const accountQueues = accountPaths.map((path) => queue(path));
  pass("every associated Storage path is enqueued exactly once",
    accountQueues.every((rows) => rows.length === 1 && rows[0].status === "PENDING"), accountQueues);
  pass("every old account object is already inaccessible",
    (await download(target.token, accountPaths[0])).status !== 200 &&
    (await download(target.token, accountPaths[1])).status !== 200);
  const accountDrain = await worker();
  pass("the worker resolves the account-deletion cleanup rows",
    accountDrain.status === 200 && accountPaths.every((path) => queue(path)[0]?.status === "DONE"),
    { response: accountDrain.json, rows: accountQueues });
  pass("an unrelated graduate's object survives account deletion",
    (await download(other.token, sentinelPath)).status === 200);
  const repeatDeletion = await request("/functions/v1/delete-graduate", {
    method: "POST",
    headers: headers(admin.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ request_id: requested.json }),
  });
  pass("repeating a completed account deletion is rejected without side effects",
    repeatDeletion.status === 404, repeatDeletion);

  // ---- Authorization: clients can never drive the worker or the queue ------------------------------
  const directDelete = await request("/rest/v1/cv_documents?id=eq." + newId, {
    method: "DELETE",
    headers: headers(owner.token, { Prefer: "return=minimal" }),
  });
  pass("authenticated clients cannot delete cv_documents directly", directDelete.status === 401 || directDelete.status === 403,
    directDelete.status);
  const userClaim = await request("/rest/v1/rpc/claim_cv_cleanup", {
    method: "POST",
    headers: headers(owner.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_limit: 1 }),
  });
  pass("authenticated clients cannot claim cleanup work", userClaim.status >= 400, userClaim);
  const userComplete = await request("/rest/v1/rpc/complete_cv_cleanup", {
    method: "POST",
    headers: headers(owner.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ p_id: leaseId }),
  });
  pass("authenticated clients cannot complete cleanup work", userComplete.status >= 400, userComplete);
  const userReport = await request("/rest/v1/rpc/get_cv_cleanup_report", {
    method: "POST",
    headers: headers(owner.token, { "Content-Type": "application/json" }),
    body: "{}",
  });
  pass("authenticated clients cannot read the cleanup report", userReport.status >= 400, userReport);
  const exposedQueue = await request("/rest/v1/cv_cleanup_queue?select=id", { headers: headers(owner.token) });
  pass("the private cleanup queue is not exposed through PostgREST", exposedQueue.status === 404, exposedQueue.status);
  const userWorker = await worker(owner.token);
  pass("the worker endpoint rejects an ordinary authenticated token", userWorker.status === 403, userWorker);
  const anonymousWorker = await worker("");
  pass("the worker endpoint rejects an unauthenticated request", anonymousWorker.status === 401 || anonymousWorker.status === 403,
    anonymousWorker);
  const workerBody = await worker();
  pass("the worker response exposes only counts, never storage paths or CV data",
    workerBody.status === 200 && Object.keys(workerBody.json ?? {}).sort().join(",") === "done,failed,processed",
    workerBody.json);
} finally {
  // Remove metadata through the owner RPC so every leftover fixture is queued, then drain it.
  for (const path of staleObjects) {
    const id = sql("select coalesce(max(id::text), '') from public.cv_documents where storage_path = " + quote(path));
    if (id) {
      await request("/rest/v1/cv_documents?id=eq." + id, { method: "DELETE", headers: headers(service) }).catch(() => {});
    }
    if (path.startsWith(owner.id + "/")) {
      await request(downloadPath(path), { method: "DELETE", headers: headers(owner.token) }).catch(() => {});
    } else if (path.startsWith(other.id + "/")) {
      await request(downloadPath(path), { method: "DELETE", headers: headers(other.token) }).catch(() => {});
    } else {
      await request(downloadPath(path), { method: "DELETE", headers: headers(service) }).catch(() => {});
    }
  }
  for (const id of createdUsers) {
    if (!id) continue;
    await request("/auth/v1/admin/users/" + id, { method: "DELETE", headers: headers(service) }).catch(() => {});
  }
  if (insertedAdminId) {
    sql("delete from private.platform_admins where user_id = " + quote(insertedAdminId));
  }
  for (let attempt = 0; attempt < 5; attempt++) {
    const drained = await worker();
    if (drained.status !== 200 || (drained.json?.processed ?? 0) === 0) break;
  }
  // Fixture-only rows that intentionally cannot be deleted are removed from the ledger.
  sql("delete from private.cv_cleanup_queue where storage_path like '%cleanup-e2e-%' and status = 'FAILED'");
}

console.log("CV CLEANUP INTEGRATION PASSED: " + passed + " checks");
