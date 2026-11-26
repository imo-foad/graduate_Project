import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const demoPassword = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && demoPassword, "local onboarding integration environment is incomplete");
assert.ok(["127.0.0.1", "localhost", "::1"].includes(new URL(base).hostname),
  "refusing to run onboarding integration against a non-local Supabase URL");

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
  return {
    status: response.status,
    ok: response.ok,
    json,
    text,
    retryAfter: response.headers.get("Retry-After"),
  };
}
const encodePath = (path) => path.split("/").map(encodeURIComponent).join("/");
const firstRow = (value) => Array.isArray(value) ? value[0] : value;
const bucket = "cv-documents";
const suffix = randomUUID().replaceAll("-", "");
const adminEmail = "p1-admin-" + suffix + "@tests.local";
const graduateEmail = "p1-graduate-" + suffix + "@tests.local";
const adminPassword = "Admin-Test-" + randomUUID() + "!x9";
const graduatePassword = "Graduate-Test-" + randomUUID() + "!x9";
let adminId = null;
let graduateId = null;
let adminToken = null;
let graduateToken = null;
let graduateCvPath = null;
let graduateRequestId = null;
let invitationId = null;
let companyId = null;
let companyJobId = null;
let passed = 0;
const pass = (name, condition, details = undefined) => {
  const message = details === undefined ? name : name + "; diagnostics=" + JSON.stringify(details);
  assert.equal(Boolean(condition), true, message);
  passed++;
  console.log("PASS " + name);
};

async function createAuthUser(email, password, fullName, extraMetadata = {}) {
  const result = await request("/auth/v1/admin/users", {
    method: "POST",
    headers: serviceHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, ...extraMetadata },
    }),
  });
  assert.ok(result.status === 200 || result.status === 201,
    "Auth Admin test-user creation failed: " + result.status + " " + result.text);
  return result.json?.user ?? result.json;
}
async function login(email, password) {
  const result = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email, password }),
  });
  assert.equal(result.status, 200, "password grant failed for " + email + ": " + result.text);
  return { token: result.json.access_token, id: result.json.user.id };
}
async function callRpc(token, name, body = {}) {
  return request("/rest/v1/rpc/" + name, {
    method: "POST",
    headers: headers(token, { "Content-Type": "application/json" }),
    body: JSON.stringify(body),
  });
}
async function authAdminUpdate(userId, changes) {
  return request("/auth/v1/admin/users/" + userId, {
    method: "PUT",
    headers: serviceHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(changes),
  });
}
async function authAdminDelete(userId) {
  return request("/auth/v1/admin/users/" + userId, {
    method: "DELETE",
    headers: serviceHeaders(),
  });
}

try {
  // Create a confirmed first-admin candidate with deliberately forged, untrusted user metadata.
  const admin = await createAuthUser(adminEmail, adminPassword, "P1 Test Admin", {
    role: "SUPER_ADMIN",
    is_admin: true,
    platform_admin: true,
  });
  adminId = admin.id;
  pass("Auth admin user created with untrusted role metadata", Boolean(adminId));

  const bootstrap = spawnSync(process.execPath, ["scripts/bootstrap-platform-admin.mjs"], {
    encoding: "utf8",
    env: {
      ...process.env,
      SUPABASE_URL: base,
      SUPABASE_SERVICE_ROLE_KEY: service,
      BOOTSTRAP_ADMIN_EMAIL: adminEmail,
      BOOTSTRAP_OPERATOR_REFERENCE: "Local integration SEC-" + suffix,
    },
    timeout: 60_000,
  });
  pass("operator-only bootstrap script creates first platform admin",
    bootstrap.status === 0 && bootstrap.stdout.includes("First platform administrator bootstrapped"));
  const bootstrapAgain = spawnSync(process.execPath, ["scripts/bootstrap-platform-admin.mjs"], {
    encoding: "utf8",
    env: {
      ...process.env,
      SUPABASE_URL: base,
      SUPABASE_SERVICE_ROLE_KEY: service,
      BOOTSTRAP_ADMIN_EMAIL: adminEmail,
      BOOTSTRAP_OPERATOR_REFERENCE: "Duplicate local integration SEC-" + suffix,
    },
    timeout: 60_000,
  });
  pass("first-admin bootstrap is one-time and duplicate attempt fails",
    bootstrapAgain.status !== 0 && /ADMIN_ALREADY_BOOTSTRAPPED/.test(
      bootstrapAgain.stderr + bootstrapAgain.stdout,
    ));

  const adminLogin = await login(adminEmail, adminPassword);
  adminToken = adminLogin.token;
  pass("bootstrapped first admin can authenticate", adminLogin.id === adminId);
  const adminGuard = await callRpc(adminToken, "assert_platform_admin");
  pass("database independently recognizes the bootstrapped admin",
    adminGuard.status === 200 && adminGuard.json === true);

  // The invitation edge verifies JWT and DB Admin status, then uses server-only Auth Admin APIs.
  const unauthenticatedInvite = await request("/functions/v1/invite-graduate", {
    method: "POST",
    headers: headers(null, { "Content-Type": "application/json" }),
    body: JSON.stringify({ email: graduateEmail, full_name: "P1 Test Graduate", verification_note: "Manual identity verification completed." }),
  });
  pass("invite endpoint rejects missing JWT", unauthenticatedInvite.status === 401);

  const invalidMetadataPayload = await request("/functions/v1/invite-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: graduateEmail,
      full_name: "P1 Test Graduate",
      verification_note: "Manual identity verification completed.",
      role: "PLATFORM_ADMIN",
      is_admin: true,
    }),
  });
  pass("invite endpoint rejects caller-supplied role/admin fields",
    invalidMetadataPayload.status === 400 && invalidMetadataPayload.json?.error === "INVALID_REQUEST");

  const invite = await request("/functions/v1/invite-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: graduateEmail,
      full_name: "P1 Test Graduate",
      verification_note: "Registrar record and government identity checked by administrator.",
    }),
  });
  pass("platform admin sends a graduate invitation",
    invite.status === 202 && invite.json?.status === "PENDING" && typeof invite.json?.invitation_id === "string");
  invitationId = invite.json?.invitation_id ?? null;

  const duplicateInvite = await request("/functions/v1/invite-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: graduateEmail.toUpperCase(),
      full_name: "Duplicate Graduate",
      verification_note: "Duplicate registrar identity request must be refused.",
    }),
  });
  pass("same normalized email cannot receive a second active invitation",
    duplicateInvite.status === 409 && duplicateInvite.json?.error === "INVITATION_ALREADY_ACTIVE");

  const invitationRows = await callRpc(adminToken, "list_graduate_invitations", {
    p_status: "PENDING",
    p_limit: 100,
  });
  pass("admins can inspect the private invitation ledger",
    invitationRows.status === 200 &&
    invitationRows.json?.some((row) => row.invitation_id === invitationId && row.email === graduateEmail));

  // A regular graduate cannot use any of the admin Edge Function capabilities.
  const demoLogin = await login("graduate.demo@alumni.test", demoPassword);
  const nonAdminInvite = await request("/functions/v1/invite-graduate", {
    method: "POST",
    headers: headers(demoLogin.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      email: "forbidden-" + suffix + "@tests.local",
      full_name: "Forbidden User",
      verification_note: "This must never be accepted from a graduate.",
    }),
  });
  pass("ordinary graduate cannot invite new accounts",
    nonAdminInvite.status === 403 && nonAdminInvite.json?.error === "ADMIN_REQUIRED");
  const nonAdminManage = await request("/functions/v1/manage-graduate", {
    method: "POST",
    headers: headers(demoLogin.token, { "Content-Type": "application/json" }),
    body: JSON.stringify({ user_id: demoLogin.id, action: "SUSPEND", reason: "Unauthorized role escalation attempt" }),
  });
  pass("ordinary graduate cannot suspend accounts",
    nonAdminManage.status === 403 && nonAdminManage.json?.error === "ADMIN_REQUIRED");

  // Simulate the trusted Auth invitation acceptance event and verify the SQL trigger updates status.
  const authInviteUsers = await request("/auth/v1/admin/users?page=1&perPage=100", {
    headers: serviceHeaders(),
  });
  const authUsers = authInviteUsers.json?.users ?? [];
  const inviteUser = authUsers.find((user) => user.email === graduateEmail);
  assert.ok(inviteUser?.id, "Auth invited user must exist");
  graduateId = inviteUser.id;
  const confirmInvite = await authAdminUpdate(graduateId, {
    email_confirm: true,
    password: graduatePassword,
  });
  assert.equal(confirmInvite.status, 200, "Auth invitation confirmation fixture failed: " + confirmInvite.text);
  const confirmedRows = await callRpc(adminToken, "list_graduate_invitations", {
    p_status: "ACCEPTED",
    p_limit: 100,
  });
  pass("Auth email confirmation moves invitation to ACCEPTED",
    confirmedRows.status === 200 &&
    confirmedRows.json?.some((row) => row.invitation_id === invitationId && row.auth_user_id === graduateId));

  const graduate = await login(graduateEmail, graduatePassword);
  graduateToken = graduate.token;
  pass("invited graduate can sign in after confirmation", graduate.id === graduateId);

  // A forged role in user_metadata never grants admin capability.
  const forgedAdmin = await callRpc(graduateToken, "assert_platform_admin");
  pass("forged user_metadata role does not confer platform-admin privilege",
    forgedAdmin.status === 403 && forgedAdmin.json?.message === "ADMIN_REQUIRED");

  // Upload a private file and metadata to prove suspension and account deletion protect Storage.
  graduateCvPath = graduateId + "/onboarding-" + suffix + ".pdf";
  const pdf = Buffer.from("%PDF-1.4\n% onboarding integration fixture\n1 0 obj<<>>endobj\n%%EOF\n");
  const upload = await request("/storage/v1/object/" + bucket + "/" + encodePath(graduateCvPath), {
    method: "POST",
    headers: headers(graduateToken, { "Content-Type": "application/pdf", "x-upsert": "false" }),
    body: pdf,
  });
  pass("invited graduate can upload a private CV to their own Storage folder",
    upload.status === 200 || upload.status === 201);

  const cvMetadata = await request("/rest/v1/cv_documents", {
    method: "POST",
    headers: headers(graduateToken, { "Content-Type": "application/json", Prefer: "return=representation" }),
    body: JSON.stringify({
      graduate_id: graduateId,
      storage_path: graduateCvPath,
      file_type: "pdf",
      size_bytes: pdf.length,
    }),
  });
  pass("invited graduate can store metadata for their own CV",
    cvMetadata.status === 201 && cvMetadata.json?.length === 1);

  // Company onboarding starts with an unverified profile; only platform administration can verify it.
  const company = await callRpc(graduateToken, "create_company", {
    p_name: "P1 Verified Company " + suffix,
    p_website: "https://company-" + suffix + ".example",
    p_description: "Synthetic company created by the onboarding HTTP integration.",
  });
  const companyRow = firstRow(company.json);
  pass("invited graduate can create a pending company account",
    company.status === 200 && companyRow?.verification_status === "PENDING_REVIEW" &&
    typeof companyRow?.id === "string");
  companyId = companyRow?.id ?? null;
  assert.ok(companyId, "company onboarding must return its id");

  const companyJob = await callRpc(graduateToken, "create_company_job", {
    p_company_id: companyId,
    p_title: "P1 Verified Company Opportunity",
    p_description: "A synthetic opportunity that remains unpublished until company verification.",
  });
  const companyJobRow = firstRow(companyJob.json);
  pass("pending company owner can save a draft job",
    companyJob.status === 200 && companyJobRow?.status === "DRAFT");
  companyJobId = companyJobRow?.id ?? null;
  assert.ok(companyJobId, "company job draft id is required");

  const prematurePublish = await callRpc(graduateToken, "publish_company_job", {
    p_opportunity_id: companyJobId,
  });
  pass("unverified company cannot publish a job",
    prematurePublish.status === 422 && prematurePublish.json?.message === "COMPANY_NOT_VERIFIED");

  const untrustedCompanyReview = await callRpc(graduateToken, "review_company", {
    p_company_id: companyId,
    p_decision: "VERIFIED",
    p_note: "Graduate must not approve their own company identity.",
  });
  pass("company owner cannot approve their own verification",
    untrustedCompanyReview.status === 403 && untrustedCompanyReview.json?.message === "ADMIN_REQUIRED");

  const verification = await callRpc(adminToken, "review_company", {
    p_company_id: companyId,
    p_decision: "VERIFIED",
    p_note: "Local E2E verified the synthetic company registration record.",
  });
  const verificationRow = firstRow(verification.json);
  pass("platform admin can verify a pending company through the audited review RPC",
    verification.status === 200 && verificationRow?.verification_status === "VERIFIED",
    { status: verification.status, body: verification.json ?? verification.text });

  const verificationHistory = await request(
    "/rest/v1/company_verification_history?select=company_id,actor_user_id,old_status,new_status,note&company_id=eq." + companyId,
    { headers: headers(graduateToken) },
  );
  pass("company owner can inspect the recorded verification decision",
    verificationHistory.status === 200 && verificationHistory.json?.some((row) =>
      row.new_status === "VERIFIED" && row.old_status === "PENDING_REVIEW" &&
      row.actor_user_id === adminId));

  const publishedJob = await callRpc(graduateToken, "publish_company_job", {
    p_opportunity_id: companyJobId,
  });
  pass("verified company can publish its own draft job",
    publishedJob.status === 200 && firstRow(publishedJob.json)?.status === "ACTIVE");

  const suspend = await request("/functions/v1/manage-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      user_id: graduateId,
      action: "SUSPEND",
      reason: "Security review confirmed account must be temporarily suspended.",
    }),
  });
  pass("admin suspends graduate through audited database and Auth workflow",
    suspend.status === 200 && suspend.json?.account_status === "SUSPENDED");

  const suspendedProfile = await request("/rest/v1/profiles?select=id&id=eq." + graduateId, {
    headers: headers(graduateToken),
  });
  pass("existing JWT cannot read profile after suspension",
    suspendedProfile.status === 200 && Array.isArray(suspendedProfile.json) && suspendedProfile.json.length === 0);

  const suspendedStorage = await request("/storage/v1/object/list/" + bucket, {
    method: "POST",
    headers: headers(graduateToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({ prefix: graduateId, limit: 100 }),
  });
  pass("existing JWT cannot list private CV files after suspension",
    suspendedStorage.status === 200 && Array.isArray(suspendedStorage.json) && suspendedStorage.json.length === 0);

  const suspendedFunction = await request("/functions/v1/recommend", {
    method: "POST",
    headers: headers(graduateToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({}),
  });
  pass("existing JWT cannot call user Edge Functions after suspension",
    suspendedFunction.status === 403 && suspendedFunction.json?.error === "UNAUTHENTICATED" ||
    suspendedFunction.status === 403 && suspendedFunction.json?.error === "ACCOUNT_UNAVAILABLE");

  const reactivate = await request("/functions/v1/manage-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({
      user_id: graduateId,
      action: "REACTIVATE",
      reason: "Security review cleared the account and restored access.",
    }),
  });
  pass("admin reactivates graduate and restores Auth sign-in",
    reactivate.status === 200 && reactivate.json?.account_status === "ACTIVE");

  const activeProfile = await request("/rest/v1/profiles?select=id&id=eq." + graduateId, {
    headers: headers(graduateToken),
  });
  pass("existing JWT regains profile access only after reactivation",
    activeProfile.status === 200 && activeProfile.json?.length === 1);

  // Deletion must be explicitly requested by the user and approved by an administrator.
  const deletionRequest = await callRpc(graduateToken, "request_account_deletion", {
    p_reason: "Please erase this test graduate account and all private CV data.",
  });
  assert.equal(deletionRequest.status, 200, "graduate deletion request failed: " + deletionRequest.text);
  graduateRequestId = deletionRequest.json;
  pass("graduate can request account deletion and receives a request id",
    typeof graduateRequestId === "string" && graduateRequestId.length > 20);

  const deletionQueue = await callRpc(adminToken, "get_account_deletion_queue", {
    p_status: "REQUESTED",
    p_limit: 100,
  });
  pass("admins can view the pending account deletion request",
    deletionQueue.status === 200 &&
    deletionQueue.json?.some((row) => row.request_id === graduateRequestId && row.user_id === graduateId));

  const approval = await callRpc(adminToken, "review_account_deletion_request", {
    p_request_id: graduateRequestId,
    p_decision: "APPROVE",
    p_note: "Verified the account and approved the test deletion request.",
  });
  pass("admin can approve account deletion after review", approval.status === 200 && approval.json === "APPROVED");

  // Company creator deletion is blocked until platform administration transfers ownership.
  const blockedDeletion = await request("/functions/v1/delete-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({ request_id: graduateRequestId }),
  });
  pass("approved deletion is blocked while the graduate still owns a company",
    blockedDeletion.status === 409 &&
    blockedDeletion.json?.error === "COMPANY_OWNERSHIP_TRANSFER_REQUIRED");

  const ownershipTransfer = await callRpc(adminToken, "transfer_company_creator", {
    p_company_id: companyId,
    p_new_owner_id: demoLogin.id,
    p_reason: "Transfer the test company to an active account before deleting its creator.",
  });
  pass("admin transfers company ownership before deleting its original creator",
    ownershipTransfer.status === 200 && ownershipTransfer.json === true);

  const deletion = await request("/functions/v1/delete-graduate", {
    method: "POST",
    headers: headers(adminToken, { "Content-Type": "application/json" }),
    body: JSON.stringify({ request_id: graduateRequestId }),
  });
  pass("approved deletion removes Storage objects and hard-deletes Auth user",
    deletion.status === 200 && deletion.json?.status === "COMPLETED");

  const deletedUser = await request("/auth/v1/admin/users/" + graduateId, {
    headers: serviceHeaders(),
  });
  pass("deleted graduate no longer exists in Supabase Auth",
    deletedUser.status === 404);

  const remainingStorage = await request("/storage/v1/object/list/" + bucket, {
    method: "POST",
    headers: serviceHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify({ prefix: graduateId, limit: 100 }),
  });
  pass("all user-owned private CV objects are removed before Auth deletion",
    remainingStorage.status === 200 && Array.isArray(remainingStorage.json) && remainingStorage.json.length === 0);

  const completedQueue = await callRpc(adminToken, "get_account_deletion_queue", {
    p_status: "COMPLETED",
    p_limit: 100,
  });
  pass("Auth deletion trigger finalizes the audit/deletion request",
    completedQueue.status === 200 &&
    completedQueue.json?.some((row) => row.request_id === graduateRequestId));

  console.log("ONBOARDING HTTP INTEGRATION PASSED: " + passed + " checks");
} finally {
  if (companyJobId) {
    const cleanupJob = await request("/rest/v1/opportunities?id=eq." + companyJobId, {
      method: "DELETE",
      headers: serviceHeaders(),
    }).catch(() => ({ ok: false }));
    assert.ok(cleanupJob.ok, "temporary company opportunity cleanup must succeed");
  }
  if (companyId) {
    const cleanupCompany = await request("/rest/v1/companies?id=eq." + companyId, {
      method: "DELETE",
      headers: serviceHeaders(),
    }).catch(() => ({ ok: false }));
    assert.ok(cleanupCompany.ok, "temporary company cleanup must succeed");
  }
  if (graduateId) {
    // If any earlier assertion failed, do not leave a test identity or its private objects behind.
    await request("/storage/v1/object/" + bucket, {
      method: "DELETE",
      headers: serviceHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ prefixes: [graduateCvPath].filter(Boolean) }),
    }).catch(() => undefined);
    const lookup = await request("/auth/v1/admin/users/" + graduateId, { headers: serviceHeaders() }).catch(() => ({ status: 0 }));
    if (lookup.status === 200) await authAdminDelete(graduateId).catch(() => undefined);
  }
  if (adminId) {
    const lookup = await request("/auth/v1/admin/users/" + adminId, { headers: serviceHeaders() }).catch(() => ({ status: 0 }));
    if (lookup.status === 200) await authAdminDelete(adminId).catch(() => undefined);
  }
}
