import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && password, "local rate-limit integration environment is incomplete");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(base).hostname),
  "refusing to run against a non-local Supabase URL");

const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
async function request(path, init = {}) {
  const response = await fetch(base + path, {
    ...init,
    signal: init.signal ?? AbortSignal.timeout(60_000),
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* retain raw text for diagnostics */ }
  return {
    status: response.status,
    ok: response.ok,
    json,
    text,
    retryAfter: response.headers.get("Retry-After"),
  };
}
const login = await request("/auth/v1/token?grant_type=password", {
  method: "POST",
  headers: headers(null, { "Content-Type": "application/json" }),
  body: JSON.stringify({ email: "graduate.demo@alumni.test", password }),
});
assert.equal(login.status, 200, "rate-limit probe graduate must authenticate");
const token = login.json.access_token;
const graduateId = login.json.user.id;

const insertedIds = [];
try {
  // CV_PARSE has a five-token initial bucket. Earlier CV integration cases use the
  // same demo account; keep submitting isolated metadata rows until the bucket blocks.
  let rateLimited = null;
  let completedAttempts = 0;
  for (let i = 0; i < 8; i++) {
    const id = randomUUID();
    const storagePath = graduateId + "/rate-limit-probe-" + randomUUID() + ".pdf";
    const insert = await request("/rest/v1/cv_documents", {
      method: "POST",
      headers: headers(token, {
        "Content-Type": "application/json",
        Prefer: "return=representation",
      }),
      body: JSON.stringify({
        graduate_id: graduateId,
        storage_path: storagePath,
        file_type: "pdf",
        size_bytes: 100,
      }),
    });
    assert.equal(insert.status, 201, "probe CV metadata must be insertable");
    assert.equal(insert.json?.[0]?.id, id, "server must preserve the generated CV id");
    insertedIds.push(id);

    const parsed = await request("/functions/v1/parse-cv", {
      method: "POST",
      headers: headers(token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ cv_document_id: id }),
    });
    completedAttempts++;
    if (parsed.status === 429) {
      rateLimited = { id, parsed };
      break;
    }
    assert.equal(parsed.status, 502,
      "missing probe Storage object should fail after a quota token is consumed");
    assert.equal(parsed.json?.error, "CV_DOWNLOAD_FAILED");
  }

  assert.ok(rateLimited, "CV parsing must return HTTP 429 after the per-user bucket is exhausted");
  assert.equal(rateLimited.parsed.json?.error, "RATE_LIMIT_EXCEEDED");
  assert.ok(Number(rateLimited.parsed.retryAfter) > 0, "429 must include a positive Retry-After header");
  const rejectedState = await request(
    "/rest/v1/cv_documents?select=parse_status&id=eq." + rateLimited.id,
    { headers: headers(token) },
  );
  assert.equal(rejectedState.status, 200);
  assert.equal(rejectedState.json?.[0]?.parse_status, "PENDING",
    "rate-limited request must release its processing claim back to PENDING");
  console.log("PASS CV parse returns 429 with Retry-After and releases its claim");
  console.log("PASS CV parse token bucket rejected attempt " + completedAttempts);

  // Force recomputation has a separate ten-token hourly budget. All earlier integration
  // requests for this demo account are included in that budget.
  let forceLimited = null;
  for (let i = 0; i < 16; i++) {
    const result = await request("/functions/v1/recommend", {
      method: "POST",
      headers: headers(token, { "Content-Type": "application/json" }),
      body: JSON.stringify({ force: true }),
    });
    if (result.status === 429) {
      forceLimited = result;
      break;
    }
    assert.equal(result.status, 200, "forced recommendation should work until its quota is exhausted");
    assert.equal(typeof result.json?.source, "string");
  }
  assert.ok(forceLimited, "forced recommendation must eventually return HTTP 429");
  assert.equal(forceLimited.json?.error, "RATE_LIMIT_EXCEEDED");
  assert.ok(Number(forceLimited.retryAfter) > 0, "recommendation 429 must include Retry-After");

  // Malformed request bodies are rejected before quota consumption and do not reveal
  // any service-role capabilities to the client.
  const malformed = await request("/functions/v1/recommend", {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ force: "true", graduate_id: graduateId }),
  });
  assert.equal(malformed.status, 400);
  assert.equal(malformed.json?.error, "INVALID_REQUEST");
  console.log("PASS forced recommendation returns 429 with Retry-After");
  console.log("PASS recommendation rejects untrusted/invalid body fields");
} finally {
  for (const id of insertedIds) {
    const cleanup = await request("/rest/v1/cv_documents?id=eq." + id, {
      method: "DELETE",
      headers: headers(token),
    }).catch(() => ({ ok: false }));
    assert.ok(cleanup.ok, "rate-limit probe metadata cleanup must succeed");
  }
}

console.log("RATE-LIMIT HTTP INTEGRATION PASSED");
