// Local-only registration integration: synthetic registry -> email confirmation -> finalize.
// Proves that registration no longer requests an SMS OTP and that activation requires both a
// confirmed email and an associated synthetic identity. Uses the real local Supabase gateway,
// GoTrue, Mailpit and the served register/finalize Edge Functions.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const mailpit = (process.env.MAILPIT_URL ?? "http://127.0.0.1:54324").replace(/\/$/, "");
assert.ok(base && anon && service, "local registration integration environment is incomplete");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(base).hostname),
  "refusing to run registration integration against a non-local Supabase URL");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(mailpit).hostname),
  "refusing to use a non-local Mailpit URL");

const headers = (token, extra = {}) => ({
  apikey: anon,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...extra,
});
const serviceHeaders = (extra = {}) => ({
  apikey: service,
  Authorization: "Bearer " + service,
  ...extra,
});
async function request(path, init = {}) {
  const response = await fetch(base + path, {
    ...init,
    signal: init.signal ?? AbortSignal.timeout(60_000),
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* keep text for diagnostics */ }
  return { status: response.status, ok: response.ok, json, text, headers: response.headers };
}
async function mailpitRequest(path) {
  const response = await fetch(mailpit + path, { signal: AbortSignal.timeout(30_000) });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* keep text */ }
  return { status: response.status, ok: response.ok, json, text };
}
async function listAuthUsers() {
  const users = [];
  for (let page = 1; page <= 10; page += 1) {
    const result = await request(`/auth/v1/admin/users?page=${page}&per_page=1000`, {
      headers: serviceHeaders(),
    });
    assert.equal(result.status, 200, "Auth Admin list failed: " + result.status + " " + result.text);
    const pageUsers = Array.isArray(result.json) ? result.json : result.json?.users;
    assert.ok(Array.isArray(pageUsers), "unexpected Auth Admin users response");
    users.push(...pageUsers);
    if (pageUsers.length < 1000) return users;
  }
  throw new Error("Auth users exceed bounded pagination limit");
}
async function authUserByEmail(email) {
  return (await listAuthUsers()).find((user) => user.email === email) ?? null;
}
async function deleteAuthUser(userId) {
  if (!userId) return;
  await request(`/auth/v1/admin/users/${userId}`, { method: "DELETE", headers: serviceHeaders() });
}
async function profileByEmail(email) {
  const result = await request(`/rest/v1/profiles?select=id,email,phone,account_status,email_verified_at&email=eq.${encodeURIComponent(email)}`, {
    headers: serviceHeaders(),
  });
  assert.equal(result.status, 200, "service profile read failed: " + result.text);
  return Array.isArray(result.json) ? result.json[0] ?? null : null;
}
async function identitiesFor(profileId) {
  const result = await request(`/rest/v1/human_identities?select=identity_type,status,verification_source,institution_ref&profile_id=eq.${profileId}`, {
    headers: serviceHeaders(),
  });
  assert.equal(result.status, 200, "service identity read failed: " + result.text);
  return Array.isArray(result.json) ? result.json : [];
}

const suffix = randomUUID().replaceAll("-", "").slice(0, 16);
const email = `reg-it-${suffix}@tests.local`;
const secondEmail = `reg-it-dup-${suffix}@tests.local`;
const phone = "+1555555" + String(1000 + Math.floor(Math.random() * 8000)).padStart(4, "0");
const password = "Registration-Test-" + randomUUID() + "!x9";
const syntheticId = "SYNTH-STUDENT-0001";
const registrationBody = {
  email,
  phone,
  password,
  full_name: "Registration Integration Student",
  synthetic_id: syntheticId,
};
let createdUserId = null;
let passed = 0;
const pass = (name, condition, details = undefined) => {
  assert.equal(Boolean(condition), true,
    details === undefined ? name : name + "; diagnostics=" + JSON.stringify(details));
  passed++;
  console.log("PASS " + name);
};

async function latestConfirmationMessage(targetEmail) {
  const list = await mailpitRequest("/api/v1/messages?limit=50");
  assert.equal(list.status, 200, "Mailpit message list failed: " + list.text);
  const messages = (list.json?.messages ?? [])
    .filter((message) => (message.To ?? []).some((to) => to.Address === targetEmail))
    .sort((a, b) => String(b.Date).localeCompare(String(a.Date)));
  assert.ok(messages.length > 0, "no confirmation email found in Mailpit for " + targetEmail);
  const detail = await mailpitRequest("/api/v1/message/" + encodeURIComponent(messages[0].ID));
  assert.equal(detail.status, 200, "Mailpit message read failed: " + detail.text);
  const text = detail.json?.Text ?? "";
  const link = text.match(/https?:\/\/[^\s)]+\/auth\/v1\/verify\?[^\s)]+/)?.[0];
  assert.ok(link, "confirmation email did not contain a verify link");
  return { link, subject: detail.json?.Subject ?? "", messages };
}

async function confirmEmail(link) {
  const response = await fetch(link, {
    redirect: "manual",
    headers: { apikey: anon },
    signal: AbortSignal.timeout(30_000),
  });
  assert.equal(response.status, 303, "email verification did not redirect: " + response.status);
  const location = response.headers.get("location") ?? "";
  const fragment = new URL(location).hash.replace(/^#/, "");
  const params = new URLSearchParams(fragment);
  assert.ok(params.get("access_token"), "email verification redirect did not contain an access token");
  assert.ok(params.get("refresh_token"), "email verification redirect did not contain a refresh token");
  return params.get("access_token");
}

try {
  // Remove accounts left by a previous failed local run so the fixed synthetic digest is free.
  for (const user of await listAuthUsers()) {
    if (typeof user.email === "string" && user.email.startsWith("reg-it-")) {
      await deleteAuthUser(user.id);
    }
  }

  // 1. Unknown and real-looking identifiers are rejected before any Auth account is created.
  const unknown = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ ...registrationBody, email: `reg-it-unknown-${suffix}@tests.local`, synthetic_id: "SYNTH-UNKNOWN-9999" }),
  });
  pass("unknown synthetic identifier is rejected", unknown.status === 422 && unknown.json?.error === "SYNTHETIC_IDENTITY_NOT_FOUND", unknown);
  pass("unknown identifier creates no Auth user", (await authUserByEmail(`reg-it-unknown-${suffix}@tests.local`)) === null);

  const realLooking = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ ...registrationBody, email: `reg-it-real-${suffix}@tests.local`, synthetic_id: "30001011234567" }),
  });
  pass("a real-looking National ID is rejected by the synthetic namespace", realLooking.status === 422 && realLooking.json?.error === "INVALID_SYNTHETIC_ID", realLooking);

  // 2. Valid registration: pending account, no SMS, email confirmation requested.
  const first = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify(registrationBody),
  });
  pass("registration returns PENDING_EMAIL_VERIFICATION", first.status === 202 && first.json?.status === "PENDING_EMAIL_VERIFICATION", first);
  pass("registration reports the synthetic source", first.json?.verification_source === "SYNTHETIC_SEED", first.json);
  pass("registration reports the resolved STUDENT identity", Array.isArray(first.json?.identities) && first.json.identities.includes("STUDENT"), first.json);
  pass("registration never claims email delivery", first.json?.email_confirmation === "REQUESTED" && first.json?.email_delivery === "UNCONFIRMED", first.json);
  pass("registration response contains no SMS/OTP instruction", !/sms|otp/i.test(first.text), first.text);

  const authUser = await authUserByEmail(email);
  assert.ok(authUser, "registration did not create the email Auth user");
  createdUserId = authUser.id;
  pass("email is the Auth identifier and phone is not stored in Auth", Boolean(authUser.email) && !authUser.phone, {
    email: authUser.email, phone: authUser.phone, phone_confirmed_at: authUser.phone_confirmed_at,
  });
  pass("email confirmation is still pending in Auth", !authUser.email_confirmed_at, authUser.email_confirmed_at);
  pass("Auth records that a confirmation request was made", Boolean(authUser.confirmation_sent_at), authUser.confirmation_sent_at);
  const expectedSyntheticDigest = createHash("sha256")
    .update("alumni-connect:synthetic:v1:" + syntheticId)
    .digest("hex");
  pass("synthetic digest is stored in trusted Auth app_metadata",
    authUser.app_metadata?.registration_synthetic_digest === expectedSyntheticDigest,
    authUser.app_metadata);

  const profile = await profileByEmail(email);
  assert.ok(profile, "registration did not create the profile");
  pass("profile stays PENDING_VERIFICATION", profile.account_status === "PENDING_VERIFICATION", profile);
  pass("phone is stored only as contact data", profile.phone === phone, profile);
  pass("email_verified_at is not set before confirmation", profile.email_verified_at === null, profile);
  const identities = await identitiesFor(profile.id);
  pass("synthetic STUDENT identity is associated and marked SYNTHETIC_SEED",
    identities.length === 1 && identities[0].identity_type === "STUDENT"
      && identities[0].status === "VERIFIED" && identities[0].verification_source === "SYNTHETIC_SEED",
    identities);

  // 3. Unconfirmed email cannot sign in; finalize therefore cannot be reached yet.
  const earlyLogin = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password }),
  });
  pass("unconfirmed email cannot obtain a session", earlyLogin.status >= 400, earlyLogin);

  // 4. Re-submitting the exact pending request is idempotent and does not create a second account.
  const retry = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify(registrationBody),
  });
  pass("same pending registration request is idempotent",
    retry.status === 202 && retry.json?.status === "PENDING_EMAIL_VERIFICATION"
      && retry.json?.email_confirmation === "ALREADY_REQUESTED", retry);
  const matchingUsers = (await listAuthUsers()).filter((user) => user.email === email);
  pass("retry did not create a second Auth account", matchingUsers.length === 1, { count: matchingUsers.length });
  const confirmationAfterRetry = await latestConfirmationMessage(email);
  pass("idempotent retry does not send a duplicate confirmation email",
    confirmationAfterRetry.messages.length === 1, { count: confirmationAfterRetry.messages.length });

  const earlyResend = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ ...registrationBody, resend_confirmation: true }),
  });
  pass("explicit confirmation resend is rate-limited during cooldown",
    earlyResend.status === 429 && earlyResend.json?.error === "EMAIL_RESEND_COOLDOWN"
      && Number(earlyResend.json?.retry_after_seconds) > 0, earlyResend);

  // 5. An orphaned pre-ledger Auth user can only be recovered by the exact trusted digest.
  const orphanEmail = `reg-it-orphan-${suffix}@tests.local`;
  const orphanPassword = "Orphan-Registration-" + randomUUID() + "!x9";
  const orphanDigest = createHash("sha256")
    .update("alumni-connect:synthetic:v1:SYNTH-STUDENT-0002")
    .digest("hex");
  const orphanCreated = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: serviceHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: orphanEmail,
      password: orphanPassword,
      email_confirm: false,
      user_metadata: { full_name: "Orphaned Synthetic Student", registration_flow: "EMAIL_IDENTITY_VERIFICATION" },
      app_metadata: { registration_synthetic_digest: orphanDigest },
    }),
  });
  pass("test creates an Auth-only pending registration recovery fixture",
    orphanCreated.status === 200 && Boolean(orphanCreated.json?.id), orphanCreated);

  const wrongIdentityRecovery = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: orphanEmail,
      password: orphanPassword,
      full_name: "Wrong Identity Recovery",
      synthetic_id: "SYNTH-GRADUATE-0001",
    }),
  });
  pass("orphan recovery rejects the same email with a different synthetic identity",
    wrongIdentityRecovery.status === 409 && wrongIdentityRecovery.json?.error === "EMAIL_ALREADY_REGISTERED",
    wrongIdentityRecovery);
  const orphanProfileBeforeRecovery = await profileByEmail(orphanEmail);
  pass("mismatched orphan recovery does not attach any identity",
    (await identitiesFor(orphanProfileBeforeRecovery.id)).length === 0);

  const correctIdentityRecovery = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: orphanEmail,
      password: orphanPassword,
      full_name: "Orphaned Synthetic Student",
      synthetic_id: "SYNTH-STUDENT-0002",
    }),
  });
  pass("orphan recovery succeeds for the exact synthetic identity",
    correctIdentityRecovery.status === 202
      && correctIdentityRecovery.json?.status === "PENDING_EMAIL_VERIFICATION", correctIdentityRecovery);
  const orphanProfileAfterRecovery = await profileByEmail(orphanEmail);
  const orphanIdentities = await identitiesFor(orphanProfileAfterRecovery.id);
  pass("exact orphan recovery associates the expected synthetic student identity",
    orphanIdentities.length === 1 && orphanIdentities[0].institution_ref === "SYNTH-STU-0002",
    orphanIdentities);

  // 6. Confirm through the real Mailpit email and finalize.
  const confirmation = await latestConfirmationMessage(email);
  pass("a confirmation email was actually delivered to local Mailpit", /confirm/i.test(confirmation.subject), confirmation.subject);
  const accessToken = await confirmEmail(confirmation.link);
  pass("email confirmation produced a user access token", Boolean(accessToken));

  const finalized = await request("/functions/v1/finalize-registration", {
    method: "POST",
    headers: headers(accessToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({}),
  });
  pass("finalize activates the account", finalized.status === 200 && finalized.json?.account_status === "ACTIVE", finalized);
  pass("finalize reports one verified identity", finalized.json?.verified_identities === 1, finalized.json);
  pass("finalize reports the email verification timestamp", Boolean(finalized.json?.email_verified_at), finalized.json);

  const activeProfile = await profileByEmail(email);
  pass("profile becomes ACTIVE", activeProfile.account_status === "ACTIVE", activeProfile);
  pass("email_verified_at is persisted", Boolean(activeProfile.email_verified_at), activeProfile);

  const secondFinalize = await request("/functions/v1/finalize-registration", {
    method: "POST",
    headers: headers(accessToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({}),
  });
  pass("finalize is idempotent for an active account", secondFinalize.status === 200 && secondFinalize.json?.account_status === "ACTIVE", secondFinalize);

  // 7. One synthetic person cannot be linked to a second account.
  const duplicateIdentity = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
      body: JSON.stringify({
    ...registrationBody,
    email: secondEmail,
    phone: undefined,
  }),
  });
  pass("the same synthetic identity cannot be linked to a second email",
    duplicateIdentity.status === 409 && duplicateIdentity.json?.error === "IDENTITY_ALREADY_LINKED", duplicateIdentity);
  pass("the rejected duplicate did not leave an Auth account", (await authUserByEmail(secondEmail)) === null);

  // 8. An active email cannot be registered again.
  const duplicateEmail = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      ...registrationBody,
     synthetic_id: "SYNTH-GRADUATE-0001",
    phone: undefined,
   }),
  });
  pass("an active email cannot be registered again", duplicateEmail.status === 409 && duplicateEmail.json?.error === "EMAIL_ALREADY_REGISTERED", duplicateEmail);

  // 9. A contact phone already owned by another account is rejected.
  const duplicatePhone = await request("/functions/v1/register", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      ...registrationBody,
      email: `reg-it-phone-${suffix}@tests.local`,
      synthetic_id: "SYNTH-FACULTY-0001",
    }),
  });
  pass("a contact phone owned by another account is rejected", duplicatePhone.status === 409 && duplicatePhone.json?.error === "PHONE_ALREADY_REGISTERED", duplicatePhone);

  console.log(`REGISTRATION INTEGRATION PASSED (${passed} checks)`);
} finally {
  await deleteAuthUser(createdUserId);
  for (const user of await listAuthUsers()) {
    if (typeof user.email === "string" && user.email.startsWith("reg-it-")) {
      await deleteAuthUser(user.id);
    }
  }
}
