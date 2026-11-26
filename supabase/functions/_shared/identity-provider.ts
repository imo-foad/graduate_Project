// Institutional identity verification adapter (Phase 2).
//
// The university/institution is the authoritative source for whether a National ID belongs to a real
// person and which human identities it carries. No real endpoint or credential has been supplied, so the
// real integration is BLOCKED_EXTERNAL. This module provides:
//   * strict local input validation (National ID format, phone E.164);
//   * a keyed deterministic digest so the raw National ID is never stored;
//   * a provider interface with an HTTP implementation and a deterministic synthetic mock;
//   * a factory that refuses to use the mock unless explicitly enabled.
// The mock proves adapter/test behaviour only; it is not evidence of a real integration.

export const IDENTITY_TYPES = ["STUDENT", "GRADUATE", "FACULTY"] as const;
export type IdentityType = (typeof IDENTITY_TYPES)[number];

export interface VerifiedIdentity {
  identity_type: IdentityType;
  institution_ref: string;
  attributes: Record<string, unknown>;
}
export interface IdentityProviderInput {
  nationalId: string;
  phone: string;
}
export interface IdentityVerificationResult {
  verified: boolean;
  provider: string;
  provider_reference: string | null;
  display_name: string | null;
  identities: VerifiedIdentity[];
  error_code: string | null;
}
export interface IdentityProvider {
  readonly name: string;
  verify(input: IdentityProviderInput): Promise<IdentityVerificationResult>;
}

export class IdentityInputError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "IdentityInputError";
    this.code = code;
  }
}

/** Removes spaces/dashes, rejects anything that is not a plausible 14-digit institutional ID. */
export function normalizeNationalId(raw: unknown): string {
  if (typeof raw !== "string") throw new IdentityInputError("INVALID_NATIONAL_ID", "National ID must be a string");
  const normalized = raw.replace(/[\s-]/g, "");
  if (!/^[0-9]{14}$/.test(normalized)) {
    throw new IdentityInputError("INVALID_NATIONAL_ID", "National ID must contain exactly 14 digits");
  }
  const century = normalized[0];
  const month = Number(normalized.slice(3, 5));
  const day = Number(normalized.slice(5, 7));
  if ((century !== "2" && century !== "3") || month < 1 || month > 12 || day < 1 || day > 31) {
    throw new IdentityInputError("INVALID_NATIONAL_ID", "National ID contains an invalid date/century");
  }
  if (/^(\d)\1{13}$/.test(normalized)) {
    throw new IdentityInputError("INVALID_NATIONAL_ID", "National ID cannot be a repeated digit");
  }
  return normalized;
}

export function normalizePhone(raw: unknown): string {
  if (typeof raw !== "string") throw new IdentityInputError("INVALID_PHONE", "Phone must be a string");
  const normalized = raw.replace(/[\s()-]/g, "");
  if (!/^\+[1-9][0-9]{7,14}$/.test(normalized)) {
    throw new IdentityInputError("INVALID_PHONE", "Phone must be in E.164 format, e.g. +201234567890");
  }
  return normalized;
}

/** Keyed digest (HMAC-SHA256). A plain unkeyed hash is not acceptable for a low-entropy identifier. */
export async function nationalIdDigest(secret: string, normalizedNationalId: string): Promise<string> {
  if (typeof secret !== "string" || secret.length < 32) {
    throw new IdentityInputError("WEAK_DIGEST_SECRET", "The digest secret must be at least 32 characters");
  }
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(normalizedNationalId));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function validatedIdentities(value: unknown): VerifiedIdentity[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 5) {
    throw new IdentityInputError("INVALID_PROVIDER_RESPONSE", "Provider returned no usable identities");
  }
  return value.map((item) => {
    if (!item || typeof item !== "object") throw new IdentityInputError("INVALID_PROVIDER_RESPONSE", "Bad identity");
    const candidate = item as Record<string, unknown>;
    const type = candidate.identity_type;
    const institution = candidate.institution_ref;
    if (typeof type !== "string" || !(IDENTITY_TYPES as readonly string[]).includes(type)) {
      throw new IdentityInputError("INVALID_PROVIDER_RESPONSE", "Provider returned an unsupported identity type");
    }
    if (typeof institution !== "string" || institution.trim().length === 0 || institution.length > 120) {
      throw new IdentityInputError("INVALID_PROVIDER_RESPONSE", "Provider returned an invalid institution reference");
    }
    const attributes = candidate.attributes && typeof candidate.attributes === "object" && !Array.isArray(candidate.attributes)
      ? candidate.attributes as Record<string, unknown> : {};
    return { identity_type: type as IdentityType, institution_ref: institution.trim(), attributes };
  });
}

/** Synthetic identities for local/disposable tests only. These are not real people. */
export const SYNTHETIC_IDENTITIES: Readonly<Record<string, { display_name: string; identities: VerifiedIdentity[] }>> = {
  "30001011234567": {
    display_name: "Sara Synthetic Graduate",
    identities: [{ identity_type: "GRADUATE", institution_ref: "CAIRO_UNIVERSITY_SYNTHETIC", attributes: { college: "Computers and Information" } }],
  },
  "30001011234568": {
    display_name: "Omar Synthetic Student",
    identities: [{ identity_type: "STUDENT", institution_ref: "CAIRO_UNIVERSITY_SYNTHETIC", attributes: { year: 3 } }],
  },
  "30001011234569": {
    display_name: "Mona Synthetic Faculty",
    identities: [{ identity_type: "FACULTY", institution_ref: "AIN_SHAMS_UNIVERSITY_SYNTHETIC", attributes: { department: "Computer Science" } }],
  },
  "30001011234570": {
    display_name: "Ali Synthetic Multi-Identity",
    identities: [
      { identity_type: "GRADUATE", institution_ref: "CAIRO_UNIVERSITY_SYNTHETIC", attributes: {} },
      { identity_type: "FACULTY", institution_ref: "AIN_SHAMS_UNIVERSITY_SYNTHETIC", attributes: {} },
    ],
  },
};

/** Deterministic local mock. It never invents a successful response for an unknown identifier. */
export class MockIdentityProvider implements IdentityProvider {
  readonly name = "mock-institutional-identity";
  private readonly records: Readonly<Record<string, { display_name: string; identities: VerifiedIdentity[] }>>;
  constructor(records = SYNTHETIC_IDENTITIES) { this.records = records; }

  async verify(input: IdentityProviderInput): Promise<IdentityVerificationResult> {
    const nationalId = normalizeNationalId(input.nationalId);
    normalizePhone(input.phone);
    const record = this.records[nationalId];
    if (!record) {
      return {
        verified: false, provider: this.name, provider_reference: null, display_name: null,
        identities: [], error_code: "NATIONAL_ID_NOT_FOUND",
      };
    }
    return {
      verified: true, provider: this.name, provider_reference: "synthetic:" + nationalId.slice(-4),
      display_name: record.display_name, identities: record.identities.map((identity) => ({
        ...identity, attributes: { ...identity.attributes },
      })), error_code: null,
    };
  }
}

/** HTTP adapter for the real institutional API. The contract is documented, the endpoint is supplied. */
export class HttpIdentityProvider implements IdentityProvider {
  readonly name: string;
  private readonly endpoint: string;
  private readonly token: string;
  private readonly timeoutMs: number;

  constructor(endpoint: string, token: string, name = "institutional-identity-http", timeoutMs = 10_000) {
    if (!/^https:\/\//.test(endpoint)) throw new IdentityInputError("INSECURE_PROVIDER_ENDPOINT", "Provider endpoint must use HTTPS");
    if (token.length < 8) throw new IdentityInputError("MISSING_PROVIDER_TOKEN", "Provider token is missing");
    this.endpoint = endpoint;
    this.token = token;
    this.name = name;
    this.timeoutMs = timeoutMs;
  }

  async verify(input: IdentityProviderInput): Promise<IdentityVerificationResult> {
    const nationalId = normalizeNationalId(input.nationalId);
    const phone = normalizePhone(input.phone);
    let response: Response;
    try {
      response = await fetch(this.endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + this.token },
        body: JSON.stringify({ national_id: nationalId, phone }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      return {
        verified: false, provider: this.name, provider_reference: null, display_name: null,
        identities: [], error_code: "IDENTITY_PROVIDER_UNAVAILABLE",
      };
    }
    if (!response.ok) {
      // Never include a response body in an error path: it may echo identity data.
      return {
        verified: false, provider: this.name, provider_reference: null, display_name: null,
        identities: [], error_code: "IDENTITY_PROVIDER_ERROR",
      };
    }
    const body = await response.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || body.verified !== true) {
      return {
        verified: false, provider: this.name, provider_reference: null, display_name: null, identities: [],
        error_code: typeof body?.error_code === "string" ? body.error_code : "NATIONAL_ID_NOT_FOUND",
      };
    }
    return {
      verified: true, provider: this.name,
      provider_reference: typeof body.provider_reference === "string" ? body.provider_reference : null,
      display_name: typeof body.display_name === "string" ? body.display_name : null,
      identities: validatedIdentities(body.identities),
      error_code: null,
    };
  }
}

export interface IdentityProviderEnv {
  IDENTITY_PROVIDER_MODE?: string;
  IDENTITY_PROVIDER_URL?: string;
  IDENTITY_PROVIDER_TOKEN?: string;
  ALLOW_MOCK_IDENTITY?: string;
}

/**
 * Returns null when no approved provider is configured (BLOCKED_EXTERNAL). The mock is never selected
 * implicitly, and never when ALLOW_MOCK_IDENTITY is not exactly "true".
 */
export function createIdentityProviderFromEnv(env: IdentityProviderEnv): IdentityProvider | null {
  const mode = (env.IDENTITY_PROVIDER_MODE ?? "").toLowerCase();
  if (mode === "mock") {
    if (env.ALLOW_MOCK_IDENTITY !== "true") return null;
    return new MockIdentityProvider();
  }
  if (mode === "http") {
    if (!env.IDENTITY_PROVIDER_URL || !env.IDENTITY_PROVIDER_TOKEN) return null;
    return new HttpIdentityProvider(env.IDENTITY_PROVIDER_URL, env.IDENTITY_PROVIDER_TOKEN);
  }
  if (env.IDENTITY_PROVIDER_URL && env.IDENTITY_PROVIDER_TOKEN) {
    return new HttpIdentityProvider(env.IDENTITY_PROVIDER_URL, env.IDENTITY_PROVIDER_TOKEN);
  }
  return null;
}
