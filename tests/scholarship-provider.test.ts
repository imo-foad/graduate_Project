import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createProviderSignature,
  parseScholarshipProviderConfigs,
  readBoundedTextStream,
  sendScholarshipApplicationToProvider,
  ScholarshipProviderError,
  sha256Hex,
  verifyProviderWebhookSignature,
} from "../supabase/functions/_shared/scholarship-provider.ts";

const secret = "provider-webhook-test-secret-" + "x".repeat(32);
const config = {
  endpoint: "https://provider.example.com/api/scholarship-applications",
  bearer_token: "provider-token-" + "x".repeat(24),
  webhook_secret: secret,
};

test("provider configuration is secret-shaped, HTTPS-only and bounded", () => {
  assert.deepEqual(parseScholarshipProviderConfigs(undefined), {});
  const parsed = parseScholarshipProviderConfigs(JSON.stringify({ PROVIDER_A: config }));
  assert.equal(parsed.PROVIDER_A.endpoint, config.endpoint);
  assert.throws(() => parseScholarshipProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "http://provider.example.test/api" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseScholarshipProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://127.0.0.1:8080/private" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseScholarshipProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://[::1]:8443/private" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseScholarshipProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://scholarship-api.internal/submit" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseScholarshipProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, bearer_token: "short" },
  })), /INVALID_PROVIDER_CREDENTIALS/);
  assert.throws(() => parseScholarshipProviderConfigs("not-json"), /INVALID_PROVIDER_CONFIG_JSON/);
});

test("HMAC callback signature accepts exact body and rejects body tampering", async () => {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const body = JSON.stringify({
    provider_key: "PROVIDER_A",
    event_id: "event-123",
    application_reference: "provider-app-123",
    status: "IN_REVIEW",
  });
  const signature = await createProviderSignature(secret, timestamp, body);
  assert.equal(
    await verifyProviderWebhookSignature(secret, timestamp, signature, body),
    true,
  );
  assert.equal(
    await verifyProviderWebhookSignature(secret, timestamp, signature, body + " "),
    false,
  );
  assert.equal(
    await verifyProviderWebhookSignature(secret, timestamp, signature, body, Number(timestamp) + 301),
    false,
  );
  assert.equal(
    await verifyProviderWebhookSignature(secret, "not-a-timestamp", signature, body),
    false,
  );
});

test("provider request is signed and uses stable idempotency with strict acknowledgement", async () => {
  const idempotencyKey = "aabbccdd-eeff-4111-8222-001122334455";
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const fakeFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    capturedUrl = String(input);
    capturedInit = init;
    return new Response(JSON.stringify({
      accepted: true,
      application_reference: "provider-app-123",
      request_id: "provider-request-456",
    }), { status: 202, headers: { "Content-Type": "application/json" } });
  }) as typeof fetch;

  const ack = await sendScholarshipApplicationToProvider(
    config,
    idempotencyKey,
    {
      schema_version: "1.0",
      event: "scholarship.application.submitted",
      application_id: "11111111-1111-4111-8111-111111111111",
      answers: { study_area: "Computer Science" },
    },
    fakeFetch,
  );

  assert.equal(capturedUrl, config.endpoint);
  assert.equal(capturedInit?.method, "POST");
  assert.equal(capturedInit?.redirect, "error");
  assert.equal(ack.http_status, 202);
  assert.equal(ack.application_reference, "provider-app-123");
  assert.equal(ack.request_id, "provider-request-456");

  const headers = new Headers(capturedInit?.headers);
  assert.equal(headers.get("Authorization"), "Bearer " + config.bearer_token);
  assert.equal(headers.get("Idempotency-Key"), idempotencyKey);
  const rawBody = String(capturedInit?.body);
  assert.equal(
    await verifyProviderWebhookSignature(
      secret,
      headers.get("X-Alumni-Timestamp") ?? "",
      headers.get("X-Alumni-Signature") ?? "",
      rawBody,
    ),
    true,
    "outgoing provider request must carry a verifiable HMAC signature",
  );
  assert.equal(JSON.parse(rawBody).idempotency_key, idempotencyKey);
  assert.equal((await sha256Hex(rawBody)).length, 64);
});

test("provider response streams are bounded by byte count before decoding", async () => {
  const accepted = await readBoundedTextStream(
    new Response("ok").body,
    2,
  );
  assert.equal(accepted, "ok");
  await assert.rejects(
    readBoundedTextStream(new Response("x".repeat(16 * 1024 + 1)).body, 16 * 1024),
    (error: unknown) => error instanceof RangeError && error.message === "BODY_TOO_LARGE",
  );
  await assert.rejects(
    readBoundedTextStream(new Response("ع".repeat(9000)).body, 16 * 1024),
    (error: unknown) => error instanceof RangeError && error.message === "BODY_TOO_LARGE",
    "byte count, not UTF-16 character count, enforces the limit",
  );
});

test("provider oversized response is rejected without reading an unbounded body", async () => {
  const tooLarge = (async () => new Response(
    "ع".repeat(9000),
    { status: 200, headers: { "Content-Type": "application/json" } },
  )) as typeof fetch;
  await assert.rejects(
    sendScholarshipApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, tooLarge,
    ),
    (error: unknown) => error instanceof ScholarshipProviderError &&
      error.code === "PROVIDER_RESPONSE_TOO_LARGE" && !error.retryable,
  );
});

test("provider 503 and 429 responses are retryable and respect Retry-After", async () => {
  for (const status of [429, 503]) {
    const fakeFetch = (async () => new Response(
      JSON.stringify({ error: "temporarily unavailable" }),
      { status, headers: { "Retry-After": "45" } },
    )) as typeof fetch;
    await assert.rejects(
      sendScholarshipApplicationToProvider(
        config,
        "aabbccdd-eeff-4111-8222-001122334455",
        { application_id: "test" },
        fakeFetch,
      ),
      (error: unknown) => {
        assert.ok(error instanceof ScholarshipProviderError);
        assert.equal(error.retryable, true);
        assert.equal(error.httpStatus, status);
        assert.equal(error.retryAfterSeconds, 45);
        return true;
      },
    );
  }
});

test("provider permanent 4xx and malformed acknowledgements are not retried", async () => {
  const forbidden = (async () => new Response(
    JSON.stringify({ error: "invalid credentials" }),
    { status: 403 },
  )) as typeof fetch;
  await assert.rejects(
    sendScholarshipApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, forbidden,
    ),
    (error: unknown) => error instanceof ScholarshipProviderError &&
      error.retryable === false && error.httpStatus === 403,
  );

  const malformed = (async () => new Response(
    JSON.stringify({ accepted: true }),
    { status: 200 },
  )) as typeof fetch;
  await assert.rejects(
    sendScholarshipApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, malformed,
    ),
    (error: unknown) => error instanceof ScholarshipProviderError &&
      error.code === "PROVIDER_ACK_INVALID" && error.retryable === false,
  );
});

test("network errors are converted to retryable provider errors", async () => {
  const offline = (async () => {
    throw new Error("connection reset");
  }) as typeof fetch;
  await assert.rejects(
    sendScholarshipApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, offline,
    ),
    (error: unknown) => error instanceof ScholarshipProviderError &&
      error.code === "PROVIDER_NETWORK_ERROR" && error.retryable,
  );
});

