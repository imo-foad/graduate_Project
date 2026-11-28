// Local synthetic identity registry helpers (demo MVP).
//
// The university demo has no real institutional integration. Registration verifies a clearly fake
// `SYNTH-...` identifier against the private registry in migration 0042. This module performs only
// strict input validation and the deterministic lookup digest; it never invents a verified person.
//
// This is NOT National ID verification and must never be described as such.

export const SYNTHETIC_ID_PREFIX = "SYNTH-";
export const SYNTHETIC_ID_NAMESPACE = "alumni-connect:synthetic:v1:";
export const SYNTHETIC_VERIFICATION_SOURCE = "SYNTHETIC_SEED";
export const SYNTHETIC_PROVIDER = "synthetic-registry";

export const IDENTITY_TYPES = ["STUDENT", "GRADUATE", "FACULTY"] as const;
export type IdentityType = (typeof IDENTITY_TYPES)[number];

export interface VerifiedIdentity {
  identity_type: IdentityType;
  institution_ref: string;
  attributes: Record<string, unknown>;
}

export class RegistrationInputError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "RegistrationInputError";
    this.code = code;
  }
}

/** Uppercases and trims the synthetic identifier, rejecting anything outside the demo namespace. */
export function normalizeSyntheticId(raw: unknown): string {
  if (typeof raw !== "string") {
    throw new RegistrationInputError("INVALID_SYNTHETIC_ID", "Synthetic identity must be a string");
  }
  const value = raw.trim().toUpperCase();
  if (value.length === 0 || value.length > 48 || !/^SYNTH-[A-Z0-9]+(-[A-Z0-9]+)*$/.test(value)) {
    throw new RegistrationInputError(
      "INVALID_SYNTHETIC_ID",
      "Synthetic identity must start with SYNTH- and contain only letters, digits and dashes",
    );
  }
  return value;
}

/** Deterministic SHA-256 lookup digest. Must match private.synthetic_identity_digest in SQL. */
export async function syntheticIdentityDigest(normalizedSyntheticId: string): Promise<string> {
  const normalized = normalizeSyntheticId(normalizedSyntheticId);
  const bytes = new TextEncoder().encode(SYNTHETIC_ID_NAMESPACE + normalized);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function normalizeEmail(raw: unknown): string {
  if (typeof raw !== "string") {
    throw new RegistrationInputError("INVALID_EMAIL", "Email must be a string");
  }
  const email = raw.trim().toLowerCase();
  if (email.length < 6 || email.length > 254
      || !/^[a-z0-9.!#$%&'*+/=?^_{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(email)) {
    throw new RegistrationInputError("INVALID_EMAIL", "Email is invalid");
  }
  return email;
}

/** Optional contact phone. It is never used as an Auth identifier in this flow. */
export function normalizeOptionalPhone(raw: unknown): string | null {
  if (raw === undefined || raw === null || (typeof raw === "string" && raw.trim() === "")) return null;
  if (typeof raw !== "string") {
    throw new RegistrationInputError("INVALID_PHONE", "Phone must be a string");
  }
  const phone = raw.replace(/[\s()-]/g, "");
  if (!/^\+[1-9][0-9]{7,14}$/.test(phone)) {
    throw new RegistrationInputError("INVALID_PHONE", "Phone must be E.164 format, e.g. +201234567890");
  }
  return phone;
}

export function validatePassword(raw: unknown): string {
  if (typeof raw !== "string" || raw.length < 10 || raw.length > 128) {
    throw new RegistrationInputError("WEAK_PASSWORD", "Password must be 10-128 characters");
  }
  return raw;
}

export function validateFullName(raw: unknown): string {
  if (typeof raw !== "string" || raw.trim().length < 2 || raw.length > 200) {
    throw new RegistrationInputError("INVALID_FULL_NAME", "Full name must be 2-200 characters");
  }
  return raw.trim();
}

/** Validates the registry response shape before it is written to the database. */
export function validatedIdentities(value: unknown): VerifiedIdentity[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 5) {
    throw new RegistrationInputError("INVALID_SYNTHETIC_IDENTITY_RECORD", "Registry returned no usable identities");
  }
  return value.map((item) => {
    if (!item || typeof item !== "object") {
      throw new RegistrationInputError("INVALID_SYNTHETIC_IDENTITY_RECORD", "Registry returned a bad identity");
    }
    const candidate = item as Record<string, unknown>;
    const type = candidate.identity_type;
    const institution = candidate.institution_ref;
    if (typeof type !== "string" || !(IDENTITY_TYPES as readonly string[]).includes(type)) {
      throw new RegistrationInputError("INVALID_SYNTHETIC_IDENTITY_RECORD", "Unsupported identity type");
    }
    if (typeof institution !== "string" || institution.trim().length === 0 || institution.length > 120) {
      throw new RegistrationInputError("INVALID_SYNTHETIC_IDENTITY_RECORD", "Invalid institution reference");
    }
    const attributes = candidate.attributes && typeof candidate.attributes === "object" && !Array.isArray(candidate.attributes)
      ? candidate.attributes as Record<string, unknown>
      : {};
    return { identity_type: type as IdentityType, institution_ref: institution.trim(), attributes };
  });
}

/** Last four digits are stored only as a non-sensitive hint; never store the full identifier. */
export function lastFourDigits(value: string): string | null {
  const match = value.match(/[0-9]{4}$/);
  return match ? match[0] : null;
}
