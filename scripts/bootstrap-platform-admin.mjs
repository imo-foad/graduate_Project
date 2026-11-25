// First-admin bootstrap is an operator-only, one-time action. Never run from Android or CI.
// Create and email-confirm the administrator in Supabase Auth first, then run this script.
import { strict as assert } from "node:assert";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const adminEmail = (process.env.BOOTSTRAP_ADMIN_EMAIL ?? "").trim().toLowerCase();
const operatorReference = (process.env.BOOTSTRAP_OPERATOR_REFERENCE ?? "").trim();

assert.ok(base && serviceKey, "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
assert.ok(adminEmail && adminEmail.length <= 254, "BOOTSTRAP_ADMIN_EMAIL is required");
assert.ok(operatorReference.length >= 8 && operatorReference.length <= 500,
  "BOOTSTRAP_OPERATOR_REFERENCE must be 8-500 characters");

const parsedUrl = new URL(base);
assert.ok(parsedUrl.protocol === "https:" ||
  ["127.0.0.1", "localhost", "::1"].includes(parsedUrl.hostname),
  "refusing a non-HTTPS Supabase endpoint");

const headers = {
  apikey: serviceKey,
  Authorization: "Bearer " + serviceKey,
  "Content-Type": "application/json",
};
async function request(path, init = {}) {
  const response = await fetch(base + path, {
    ...init,
    headers: { ...headers, ...(init.headers ?? {}) },
    signal: AbortSignal.timeout(30_000),
  });
  const raw = await response.text();
  let data = null;
  try { data = raw ? JSON.parse(raw) : null; } catch { /* no raw secrets are printed */ }
  if (!response.ok) {
    const message = data?.message ?? data?.msg ?? "request failed";
    throw new Error("Supabase Admin API request failed (HTTP " + response.status + "): " + message);
  }
  return data;
}

async function findConfirmedUser(email) {
  for (let page = 1; page <= 100; page++) {
    const result = await request("/auth/v1/admin/users?page=" + page + "&perPage=100");
    const users = Array.isArray(result?.users) ? result.users : [];
    const match = users.find((user) => (user.email ?? "").trim().toLowerCase() === email);
    if (match) return match;
    if (users.length < 100) return null;
  }
  throw new Error("Auth user lookup exceeded the safe pagination limit");
}

const target = await findConfirmedUser(adminEmail);
assert.ok(target?.id, "No Auth user exists for BOOTSTRAP_ADMIN_EMAIL");
assert.ok(target.email_confirmed_at || target.confirmed_at,
  "The first administrator must have a confirmed email before bootstrap");

const result = await request("/rest/v1/rpc/bootstrap_first_platform_admin", {
  method: "POST",
  body: JSON.stringify({
    p_user_id: target.id,
    p_operator_reference: operatorReference,
  }),
});

assert.equal(result, true, "First-admin bootstrap did not return success");
console.log("First platform administrator bootstrapped:", target.id);
console.log("Operator reference recorded. Service-role key was not printed.");
