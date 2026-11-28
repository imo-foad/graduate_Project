import { test } from "node:test";
import assert from "node:assert/strict";
import {
  lastFourDigits, normalizeEmail, normalizeOptionalPhone, normalizeSyntheticId,
  RegistrationInputError, syntheticIdentityDigest, validateFullName, validatePassword,
  validatedIdentities,
} from "../supabase/functions/_shared/synthetic-identity.ts";

test("synthetic identifiers are normalized strictly and never accept a real National ID", () => {
  assert.equal(normalizeSyntheticId("synth-student-0001"), "SYNTH-STUDENT-0001");
  assert.equal(normalizeSyntheticId("  SYNTH-MULTI-0001  "), "SYNTH-MULTI-0001");
  for (const bad of [
    "", "   ", "30001011234567", "SYNTH-", "SYNTH STUDENT 0001", "STUDENT-0001",
    "SYNTH-" + "A".repeat(50), null, 123,
  ]) {
    assert.throws(() => normalizeSyntheticId(bad), RegistrationInputError, JSON.stringify(bad));
  }
  try { normalizeSyntheticId("30001011234567"); } catch (error) {
    assert.equal((error as RegistrationInputError).code, "INVALID_SYNTHETIC_ID");
  }
});

test("the synthetic lookup digest is deterministic, matches the SQL namespace and is not the identifier", async () => {
  const a = await syntheticIdentityDigest("SYNTH-STUDENT-0001");
  const b = await syntheticIdentityDigest("synth-student-0001");
  assert.equal(a, b);
  assert.equal(a, "edfde02baa7e4430d1de0e5e046d37a6c18ff08abd0916f3220006d27ccbb04b");
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.notEqual(a, "SYNTH-STUDENT-0001");
});

test("email is normalized and validated; phone is optional contact data", () => {
  assert.equal(normalizeEmail("  Student@Example.TEST "), "student@example.test");
  for (const bad of ["", "student", "student@", "@example.test", "a@b", null, 5]) {
    assert.throws(() => normalizeEmail(bad), RegistrationInputError, String(bad));
  }
  assert.equal(normalizeOptionalPhone(undefined), null);
  assert.equal(normalizeOptionalPhone(""), null);
  assert.equal(normalizeOptionalPhone("+20 123 456 7890"), "+201234567890");
  for (const bad of ["01234567890", "+0123456789", "+20", "++201234567890", "phone", 5]) {
    assert.throws(() => normalizeOptionalPhone(bad), RegistrationInputError, String(bad));
  }
});

test("password and full-name validation reject weak or oversized values", () => {
  assert.equal(validatePassword("long-enough-password"), "long-enough-password");
  assert.throws(() => validatePassword("short"), RegistrationInputError);
  assert.throws(() => validatePassword("x".repeat(129)), RegistrationInputError);
  assert.equal(validateFullName("  Sara Synthetic  "), "Sara Synthetic");
  assert.throws(() => validateFullName("A"), RegistrationInputError);
  assert.throws(() => validateFullName("x".repeat(201)), RegistrationInputError);
});

test("registry identities are validated and may contain multiple approved roles", () => {
  const identities = validatedIdentities([
    { identity_type: "GRADUATE", institution_ref: "SYNTH-GRAD-0002", attributes: {} },
    { identity_type: "FACULTY", institution_ref: "SYNTH-FAC-0002", attributes: { department: "CS" } },
  ]);
  assert.deepEqual(identities.map((i) => i.identity_type), ["GRADUATE", "FACULTY"]);
  assert.throws(() => validatedIdentities([]), RegistrationInputError);
  assert.throws(() => validatedIdentities([{ identity_type: "ADMIN", institution_ref: "X" }]), RegistrationInputError);
  assert.throws(() => validatedIdentities([{ identity_type: "STUDENT", institution_ref: "" }]), RegistrationInputError);
  assert.throws(() => validatedIdentities(null), RegistrationInputError);
});

test("only a four-digit suffix is retained as a non-sensitive hint", () => {
  assert.equal(lastFourDigits("SYNTH-STUDENT-0001"), "0001");
  assert.equal(lastFourDigits("SYNTH-ABCD"), null);
});
