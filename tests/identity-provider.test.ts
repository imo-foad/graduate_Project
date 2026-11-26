import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createIdentityProviderFromEnv, IdentityInputError, MockIdentityProvider, HttpIdentityProvider,
  nationalIdDigest, normalizeNationalId, normalizePhone, SYNTHETIC_IDENTITIES,
} from "../supabase/functions/_shared/identity-provider.ts";

const SECRET = "test-only-hmac-secret-with-at-least-32-chars";

test("National ID input is normalized strictly, without ever accepting an ambiguous value", () => {
  assert.equal(normalizeNationalId("30001011234567"), "30001011234567");
  assert.equal(normalizeNationalId("300 0101 1234567"), "30001011234567");
  assert.equal(normalizeNationalId("300-0101-1234567"), "30001011234567");
  for (const bad of ["3000101123456", "300010112345678", "3000101123456a", "", "   ", "40001011234567", "30013011234567", "30001001234567", "00000000000000"]) {
    assert.throws(() => normalizeNationalId(bad), IdentityInputError, JSON.stringify(bad));
  }
  assert.throws(() => normalizeNationalId(null), IdentityInputError);
  assert.throws(() => normalizeNationalId(30001011234567), IdentityInputError);
});

test("phone numbers must be E.164", () => {
  assert.equal(normalizePhone("+201234567890"), "+201234567890");
  assert.equal(normalizePhone("+20 123 456 7890"), "+201234567890");
  for (const bad of ["01234567890", "+0123456789", "+20", "++201234567890", "phone", "", null]) {
    assert.throws(() => normalizePhone(bad), IdentityInputError, String(bad));
  }
});

test("National ID digest is keyed, deterministic and never the raw identifier", async () => {
  const id = "30001011234567";
  const a = await nationalIdDigest(SECRET, id);
  const b = await nationalIdDigest(SECRET, id);
  const otherKey = await nationalIdDigest("another-test-only-secret-32-chars-long!", id);
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.notEqual(a, otherKey);
  assert.notEqual(a, id);
  await assert.rejects(() => nationalIdDigest("short", id), IdentityInputError);
});

test("the deterministic mock verifies only synthetic identities and can return multiple roles", async () => {
  const provider = new MockIdentityProvider();
  const graduate = await provider.verify({ nationalId: "30001011234567", phone: "+201234567890" });
  assert.equal(graduate.verified, true);
  assert.deepEqual(graduate.identities.map((i) => i.identity_type), ["GRADUATE"]);

  const multi = await provider.verify({ nationalId: "30001011234570", phone: "+201234567890" });
  assert.deepEqual(multi.identities.map((i) => i.identity_type), ["GRADUATE", "FACULTY"]);

  const missing = await provider.verify({ nationalId: "30001019999999", phone: "+201234567890" });
  assert.equal(missing.verified, false);
  assert.equal(missing.error_code, "NATIONAL_ID_NOT_FOUND");
  assert.deepEqual(missing.identities, []);
});

test("synthetic fixtures cover every approved human identity type", () => {
  const types = new Set(Object.values(SYNTHETIC_IDENTITIES).flatMap((r) => r.identities.map((i) => i.identity_type)));
  assert.deepEqual([...types].sort(), ["FACULTY", "GRADUATE", "STUDENT"]);
});

test("the provider factory never selects the mock implicitly", () => {
  assert.equal(createIdentityProviderFromEnv({}), null);
  assert.equal(createIdentityProviderFromEnv({ IDENTITY_PROVIDER_MODE: "mock" }), null);
  assert.equal(createIdentityProviderFromEnv({ IDENTITY_PROVIDER_MODE: "mock", ALLOW_MOCK_IDENTITY: "false" }), null);
  assert.ok(createIdentityProviderFromEnv({ IDENTITY_PROVIDER_MODE: "mock", ALLOW_MOCK_IDENTITY: "true" }) instanceof MockIdentityProvider);
  assert.equal(createIdentityProviderFromEnv({ IDENTITY_PROVIDER_MODE: "http" }), null);
  assert.equal(createIdentityProviderFromEnv({ IDENTITY_PROVIDER_MODE: "http", IDENTITY_PROVIDER_URL: "https://id.example.test", IDENTITY_PROVIDER_TOKEN: "token-123" }) instanceof HttpIdentityProvider, true);
  assert.throws(() => new HttpIdentityProvider("http://id.example.test", "token-123"), IdentityInputError);
  assert.throws(() => new HttpIdentityProvider("https://id.example.test", "short"), IdentityInputError);
});
