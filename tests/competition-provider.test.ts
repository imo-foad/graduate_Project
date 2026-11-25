import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createProviderSignature,
  parseCompetitionProviderConfigs,
  readBoundedTextStream,
  sendCompetitionApplicationToProvider,
  CompetitionProviderError,
  sha256Hex,
  verifyProviderWebhookSignature,
} from "../supabase/functions/_shared/competition-provider.ts";
import { deliverCompetitionApplications } from "../supabase/functions/_shared/competition-delivery.ts";

const secret = "provider-webhook-test-secret-" + "x".repeat(32);
const config = {
  endpoint: "https://provider.example.com/api/competition-entries",
  bearer_token: "provider-token-" + "x".repeat(24),
  webhook_secret: secret,
};

test("provider configuration is secret-shaped, HTTPS-only and bounded", () => {
  assert.deepEqual(parseCompetitionProviderConfigs(undefined), {});
  const parsed = parseCompetitionProviderConfigs(JSON.stringify({ PROVIDER_A: config }));
  assert.equal(parsed.PROVIDER_A.endpoint, config.endpoint);
  assert.throws(() => parseCompetitionProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "http://provider.example.test/api" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseCompetitionProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://127.0.0.1:8080/private" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseCompetitionProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://[::1]:8443/private" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseCompetitionProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, endpoint: "https://competition-api.internal/submit" },
  })), /UNSAFE_PROVIDER_ENDPOINT/);
  assert.throws(() => parseCompetitionProviderConfigs(JSON.stringify({
    PROVIDER_A: { ...config, bearer_token: "short" },
  })), /INVALID_PROVIDER_CREDENTIALS/);
  assert.throws(() => parseCompetitionProviderConfigs("not-json"), /INVALID_PROVIDER_CONFIG_JSON/);
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

  const ack = await sendCompetitionApplicationToProvider(
    config,
    idempotencyKey,
    {
      schema_version: "1.0",
      event: "competition.application.submitted",
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
    sendCompetitionApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, tooLarge,
    ),
    (error: unknown) => error instanceof CompetitionProviderError &&
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
      sendCompetitionApplicationToProvider(
        config,
        "aabbccdd-eeff-4111-8222-001122334455",
        { application_id: "test" },
        fakeFetch,
      ),
      (error: unknown) => {
        assert.ok(error instanceof CompetitionProviderError);
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
    sendCompetitionApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, forbidden,
    ),
    (error: unknown) => error instanceof CompetitionProviderError &&
      error.retryable === false && error.httpStatus === 403,
  );

  const malformed = (async () => new Response(
    JSON.stringify({ accepted: true }),
    { status: 200 },
  )) as typeof fetch;
  await assert.rejects(
    sendCompetitionApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, malformed,
    ),
    (error: unknown) => error instanceof CompetitionProviderError &&
      error.code === "PROVIDER_ACK_INVALID" && error.retryable === false,
  );
});

test("network errors are converted to retryable provider errors", async () => {
  const offline = (async () => {
    throw new Error("connection reset");
  }) as typeof fetch;
  await assert.rejects(
    sendCompetitionApplicationToProvider(
      config, "aabbccdd-eeff-4111-8222-001122334455", {}, offline,
    ),
    (error: unknown) => error instanceof CompetitionProviderError &&
      error.code === "PROVIDER_NETWORK_ERROR" && error.retryable,
  );
});



function makeDeliveryAdmin(
  claimed: Record<string, unknown>,
  overrides: Record<string, (args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>> = {},
) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const admin = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      const override = overrides[name];
      if (override) return await override(args);
      if (name === "claim_competition_delivery") return { data: [claimed], error: null };
      if (name === "complete_competition_delivery") {
        return { data: { provider_application_reference: "organizer-ref-123" }, error: null };
      }
      if (name === "block_competition_delivery") return { data: true, error: null };
      if (name === "fail_competition_delivery") return { data: "PENDING", error: null };
      throw new Error("Unexpected RPC " + name);
    },
    storage: {
      from: (bucket: string) => ({
        createSignedUrl: async (path: string, expiresIn: number) => ({
          data: { signedUrl: `https://storage.example.com/${bucket}/${encodeURIComponent(path)}?expires=${expiresIn}` },
          error: null,
        }),
      }),
    },
  };
  return { admin, calls };
}

const claimedDelivery = {
  outbox_id: "aabbccdd-eeff-4111-8222-001122334455",
  application_id: "11111111-1111-4111-8111-111111111111",
  provider_key: "PROVIDER_A",
  external_opportunity_id: "organizer-competition-9",
  attempt_number: 1,
  idempotency_key: "aabbccdd-eeff-4111-8222-001122334455",
  request_payload: {
    schema_version: "1.0",
    event: "competition.application.submitted",
    application_id: "11111111-1111-4111-8111-111111111111",
    graduate_id: "22222222-2222-4222-8222-222222222222",
    cv_document_id: "33333333-3333-4333-8333-333333333333",
    applicant: { full_name: "Test Applicant", email: "applicant@example.test" },
    answers: { project_title: "Campus Assist" },
  },
  cv_storage_path: "22222222-2222-4222-8222-222222222222/cv.pdf",
};

const providerRegistry = JSON.stringify({ PROVIDER_A: config });

test("delivery worker sends a claimed application, signs it, and commits only provider acknowledgement", async () => {
  const { admin, calls } = makeDeliveryAdmin(claimedDelivery);
  let requestBody = "";
  let requestInit: RequestInit | undefined;
  const fakeFetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    requestInit = init;
    requestBody = String(init?.body ?? "");
    return new Response(JSON.stringify({
      accepted: true,
      application_reference: "organizer-ref-123",
      request_id: "request-123",
    }), { status: 202, headers: { "Content-Type": "application/json" } });
  }) as typeof fetch;

  const results = await deliverCompetitionApplications(admin, {
    applicationId: claimedDelivery.application_id,
    limit: 1,
    providerConfigJson: providerRegistry,
    fetcher: fakeFetch,
  });

  assert.deepEqual(results, [{
    application_id: claimedDelivery.application_id,
    status: "SUBMITTED_EXTERNALLY",
    delivery_status: "DELIVERED",
    provider_application_reference: "organizer-ref-123",
  }]);
  assert.deepEqual(calls.map((call) => call.name), [
    "claim_competition_delivery",
    "complete_competition_delivery",
  ]);
  const body = JSON.parse(requestBody);
  assert.equal(body.idempotency_key, claimedDelivery.idempotency_key);
  assert.equal(body.provider_opportunity_id, "organizer-competition-9");
  assert.equal(body.graduate_id, undefined, "internal graduate UUID is not sent to the organizer");
  assert.equal(body.cv_document_id, undefined, "internal CV document UUID is not sent to the organizer");
  assert.match(body.cv_download_url, /^https:\/\/storage\.example\.com\//);
  const headers = new Headers(requestInit?.headers);
  assert.equal(headers.get("Idempotency-Key"), claimedDelivery.idempotency_key);
  assert.ok(headers.get("X-Alumni-Signature")?.startsWith("sha256="));
  const completion = calls.find((call) => call.name === "complete_competition_delivery");
  assert.equal(completion?.args.p_provider_reference, "organizer-ref-123");
  assert.equal(completion?.args.p_http_status, 202);
});

test("delivery worker blocks a mapping with no provider secret and never calls the network", async () => {
  const { admin, calls } = makeDeliveryAdmin(claimedDelivery);
  let networkCalls = 0;
  const results = await deliverCompetitionApplications(admin, {
    providerConfigJson: "{}",
    fetcher: (async () => {
      networkCalls++;
      return new Response("unexpected", { status: 200 });
    }) as typeof fetch,
  });

  assert.equal(results[0]?.status, "PENDING_DELIVERY");
  assert.equal(results[0]?.delivery_status, "BLOCKED");
  assert.equal(results[0]?.error_code, "PROVIDER_NOT_CONFIGURED");
  assert.equal(networkCalls, 0);
  assert.ok(calls.some((call) => call.name === "block_competition_delivery"));
  assert.equal(calls.some((call) => call.name === "complete_competition_delivery"), false);
});

test("delivery worker persists retryable provider errors with the Retry-After delay", async () => {
  let failedArgs: Record<string, unknown> | null = null;
  const { admin, calls } = makeDeliveryAdmin(claimedDelivery, {
    fail_competition_delivery: async (args) => {
      failedArgs = args;
      return { data: "PENDING", error: null };
    },
  });
  const fakeFetch = (async () => new Response(
    JSON.stringify({ error: "temporarily unavailable" }),
    { status: 503, headers: { "Retry-After": "45" } },
  )) as typeof fetch;

  const results = await deliverCompetitionApplications(admin, {
    providerConfigJson: providerRegistry,
    fetcher: fakeFetch,
  });
  assert.equal(results[0]?.status, "PENDING_DELIVERY");
  assert.equal(results[0]?.delivery_status, "PENDING");
  assert.equal(results[0]?.error_code, "PROVIDER_HTTP_ERROR");
  assert.equal(failedArgs?.p_retryable, true);
  assert.equal(failedArgs?.p_http_status, 503);
  assert.equal(failedArgs?.p_retry_after_seconds, 45);
  assert.equal(calls.some((call) => call.name === "complete_competition_delivery"), false);
});

test("delivery worker permanently fails a provider-rejected application", async () => {
  const { admin } = makeDeliveryAdmin(claimedDelivery, {
    fail_competition_delivery: async () => ({ data: "FAILED", error: null }),
  });
  const fakeFetch = (async () => new Response(
    JSON.stringify({ error: "invalid organizer application" }),
    { status: 422 },
  )) as typeof fetch;

  const results = await deliverCompetitionApplications(admin, {
    providerConfigJson: providerRegistry,
    fetcher: fakeFetch,
  });
  assert.equal(results[0]?.status, "DELIVERY_FAILED");
  assert.equal(results[0]?.delivery_status, "FAILED");
  assert.equal(results[0]?.error_code, "PROVIDER_HTTP_ERROR");
});
