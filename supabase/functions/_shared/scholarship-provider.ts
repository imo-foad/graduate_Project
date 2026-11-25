export type ScholarshipProviderConfig = {
  endpoint: string;
  bearer_token: string;
  webhook_secret: string;
};

export type ScholarshipProviderConfigs = Record<string, ScholarshipProviderConfig>;

export type ScholarshipProviderAck = {
  application_reference: string;
  request_id: string | null;
  http_status: number;
};

export class ScholarshipProviderError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly httpStatus: number | null;
  readonly retryAfterSeconds: number | null;

  constructor(
    code: string,
    retryable: boolean,
    httpStatus: number | null = null,
    retryAfterSeconds: number | null = null,
  ) {
    super(code);
    this.name = "ScholarshipProviderError";
    this.code = code;
    this.retryable = retryable;
    this.httpStatus = httpStatus;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

const KEY_PATTERN = /^[A-Z0-9][A-Z0-9_-]{1,63}$/;
const HEX_PATTERN = /^[a-f0-9]{64}$/;
const MAX_PROVIDER_RESPONSE_BYTES = 16 * 1024;
const MAX_PROVIDER_TIMEOUT_MS = 15_000;
const encoder = new TextEncoder();

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function safeEndpoint(value: unknown): string {
  if (typeof value !== "string" || value.length > 2048) {
    throw new Error("INVALID_PROVIDER_ENDPOINT");
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("INVALID_PROVIDER_ENDPOINT");
  }
  if (
    url.protocol !== "https:" ||
    !url.hostname ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.hostname === "localhost" ||
    url.hostname.endsWith(".localhost") ||
    url.hostname.endsWith(".local") ||
    url.hostname.endsWith(".internal") ||
    url.hostname.endsWith(".lan") ||
    url.hostname.endsWith(".home") ||
    url.hostname.endsWith(".test") ||
    url.hostname.endsWith(".invalid") ||
    url.hostname.includes(":") ||
    /^\d{1,3}(\.\d{1,3}){3}$/.test(url.hostname) ||
    !url.hostname.includes(".")
  ) {
    throw new Error("UNSAFE_PROVIDER_ENDPOINT");
  }
  return url.toString();
}

export function parseScholarshipProviderConfigs(raw: string | undefined): ScholarshipProviderConfigs {
  if (!raw) return {};
  if (raw.length > 64 * 1024) throw new Error("PROVIDER_CONFIG_TOO_LARGE");

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("INVALID_PROVIDER_CONFIG_JSON");
  }
  if (!isRecord(parsed) || Object.keys(parsed).length > 20) {
    throw new Error("INVALID_PROVIDER_CONFIG");
  }

  const result: ScholarshipProviderConfigs = {};
  for (const [key, candidate] of Object.entries(parsed)) {
    if (!KEY_PATTERN.test(key) || !isRecord(candidate)) {
      throw new Error("INVALID_PROVIDER_CONFIG");
    }
    const endpoint = safeEndpoint(candidate.endpoint);
    const bearer = candidate.bearer_token;
    const webhook = candidate.webhook_secret;
    if (
      typeof bearer !== "string" || bearer.length < 16 || bearer.length > 4096 ||
      typeof webhook !== "string" || webhook.length < 32 || webhook.length > 4096
    ) {
      throw new Error("INVALID_PROVIDER_CREDENTIALS");
    }
    result[key] = {
      endpoint,
      bearer_token: bearer,
      webhook_secret: webhook,
    };
  }
  return result;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function fromHex(hex: string): Uint8Array {
  if (!HEX_PATTERN.test(hex)) throw new Error("INVALID_SIGNATURE_FORMAT");
  const bytes = new Uint8Array(32);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

async function hmacKey(secret: string, usages: KeyUsage[]): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages,
  );
}

export async function createProviderSignature(
  secret: string,
  timestamp: string,
  rawBody: string,
): Promise<string> {
  const key = await hmacKey(secret, ["sign"]);
  const signed = await crypto.subtle.sign("HMAC", key, encoder.encode(timestamp + "." + rawBody));
  return "sha256=" + toHex(new Uint8Array(signed));
}

export async function verifyProviderWebhookSignature(
  secret: string,
  timestamp: string,
  signature: string,
  rawBody: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!/^[0-9]{10}$/.test(timestamp)) return false;
  const epoch = Number(timestamp);
  if (!Number.isSafeInteger(epoch) || Math.abs(nowSeconds - epoch) > 300) return false;
  if (typeof signature !== "string" || !signature.startsWith("sha256=")) return false;

  let signatureBytes: Uint8Array;
  try {
    signatureBytes = fromHex(signature.slice("sha256=".length));
  } catch {
    return false;
  }
  const key = await hmacKey(secret, ["verify"]);
  return crypto.subtle.verify(
    "HMAC",
    key,
    signatureBytes,
    encoder.encode(timestamp + "." + rawBody),
  );
}

export async function sha256Hex(rawBody: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(rawBody));
  return toHex(new Uint8Array(digest));
}

function retryAfterSeconds(header: string | null): number | null {
  if (!header) return null;
  const seconds = Number(header);
  if (Number.isFinite(seconds) && seconds >= 1) return Math.min(3600, Math.ceil(seconds));
  const date = Date.parse(header);
  if (!Number.isFinite(date)) return null;
  const delta = Math.ceil((date - Date.now()) / 1000);
  return delta > 0 ? Math.min(3600, delta) : null;
}

export async function readBoundedTextStream(
  body: ReadableStream<Uint8Array> | null,
  maxBytes: number,
): Promise<string> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new RangeError("INVALID_MAX_BODY_BYTES");
  }
  if (!body) return "";
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new RangeError("BODY_TOO_LARGE");
      }
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

export async function sendScholarshipApplicationToProvider(
  config: ScholarshipProviderConfig,
  idempotencyKey: string,
  payload: Record<string, unknown>,
  fetcher: typeof fetch = fetch,
): Promise<ScholarshipProviderAck> {
  if (!/^[0-9a-f-]{36}$/i.test(idempotencyKey)) {
    throw new ScholarshipProviderError("INVALID_IDEMPOTENCY_KEY", false);
  }

  const body = JSON.stringify({
    ...payload,
    idempotency_key: idempotencyKey,
  });
  if (encoder.encode(body).byteLength > 64 * 1024) {
    throw new ScholarshipProviderError("PROVIDER_REQUEST_TOO_LARGE", false);
  }

  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = await createProviderSignature(config.webhook_secret, timestamp, body);

  let response: Response;
  try {
    response = await fetcher(config.endpoint, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(MAX_PROVIDER_TIMEOUT_MS),
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": "Bearer " + config.bearer_token,
        "Idempotency-Key": idempotencyKey,
        "X-Alumni-Timestamp": timestamp,
        "X-Alumni-Signature": signature,
      },
      body,
    });
  } catch {
    throw new ScholarshipProviderError("PROVIDER_NETWORK_ERROR", true);
  }

  let responseText: string;
  try {
    responseText = await readBoundedTextStream(response.body, MAX_PROVIDER_RESPONSE_BYTES);
  } catch (error) {
    if (error instanceof RangeError && error.message === "BODY_TOO_LARGE") {
      throw new ScholarshipProviderError("PROVIDER_RESPONSE_TOO_LARGE", false, response.status);
    }
    throw new ScholarshipProviderError("PROVIDER_RESPONSE_READ_FAILED", true, response.status);
  }

  let responseBody: unknown = null;
  try {
    responseBody = responseText ? JSON.parse(responseText) : null;
  } catch {
    throw new ScholarshipProviderError(
      "PROVIDER_INVALID_RESPONSE",
      response.status >= 500 || response.status === 429,
      response.status,
      retryAfterSeconds(response.headers.get("Retry-After")),
    );
  }

  if (!response.ok) {
    throw new ScholarshipProviderError(
      "PROVIDER_HTTP_ERROR",
      response.status === 408 || response.status === 425 ||
        response.status === 429 || response.status >= 500,
      response.status,
      retryAfterSeconds(response.headers.get("Retry-After")),
    );
  }

  if (
    !isRecord(responseBody) ||
    responseBody.accepted !== true ||
    typeof responseBody.application_reference !== "string" ||
    responseBody.application_reference.trim().length < 1 ||
    responseBody.application_reference.length > 200 ||
    (responseBody.request_id !== undefined &&
      responseBody.request_id !== null &&
      (typeof responseBody.request_id !== "string" || responseBody.request_id.length > 200))
  ) {
    throw new ScholarshipProviderError("PROVIDER_ACK_INVALID", false, response.status);
  }

  return {
    application_reference: responseBody.application_reference.trim(),
    request_id: typeof responseBody.request_id === "string" ? responseBody.request_id : null,
    http_status: response.status,
  };
}

