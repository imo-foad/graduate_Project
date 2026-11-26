// Local-only Auth Admin provisioning for synthetic university accounts.
// It never sends SMS and never stores credentials in fixtures or SQL.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const LOCAL_SUPABASE_API_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);

// Keep the client and database rule identical: E.164 '+' followed by 8..15 digits,
// with a non-zero first digit. Never log a complete synthetic phone number.
export function isValidE164Phone(value) {
  return typeof value === "string" && /^\+[1-9][0-9]{7,14}$/.test(value);
}

function splitPostgresTuple(value) {
  const fields = [];
  let current = "";
  let quote = null;
  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    if (quote) {
      current += ch;
      if (ch === quote) {
        if (value[i + 1] === quote) {
          current += value[i + 1];
          i += 1;
        } else {
          quote = null;
        }
      }
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      current += ch;
    } else if (ch === ",") {
      fields.push(current.trim());
      current = "";
    } else {
      current += ch;
    }
  }
  fields.push(current.trim());
  return fields;
}

function maskedPhoneShape(value, requestedPhone) {
  if (typeof value !== "string" || value.trim() === "" || value === "null") {
    return { present: false };
  }
  const phone = value.trim();
  const digits = phone.replace(/[^0-9]/g, "");
  return {
    present: true,
    length: phone.length,
    leadingPlus: phone.startsWith("+"),
    digitsOnlyAfterPlus: /^\+[0-9]+$/.test(phone),
    validE164: isValidE164Phone(phone),
    matchesRequested: phone === requestedPhone,
    lastTwoDigits: digits.slice(-2),
  };
}

function extractProfilePhoneFromDetail(detail) {
  const start = detail.indexOf("Failing row contains (");
  if (start < 0) return null;
  const rowStart = start + "Failing row contains (".length;
  const end = detail.indexOf(").", rowStart);
  if (end < 0) return null;
  const fields = splitPostgresTuple(detail.slice(rowStart, end));
  // profiles declares id, full_name, email, avatar_url, account_status, created_at,
  // updated_at, then phone. Fall back to a phone-shaped field if earlier columns evolve.
  const phoneAtCurrentSchema = fields[7];
  const looksLikePhone = (value) => /^\+?[0-9][0-9 ().-]{7,22}$/.test(value ?? "");
  if (looksLikePhone(phoneAtCurrentSchema)) return phoneAtCurrentSchema;
  return fields.find(looksLikePhone) ?? null;
}

/**
 * Returns only sanitized diagnostics. The raw Auth/Postgres error detail can include a full
 * failing database row; never forward that row to public Actions logs.
 */
export function summarizeAuthCreateFailure(responseText, requestedPhone) {
  let body = {};
  try { body = JSON.parse(responseText); } catch { /* keep only generic diagnostics */ }
  const detail = typeof body.detail === "string" ? body.detail : "";
  const message = typeof body.message === "string" ? body.message : "";
  const constraint = message.match(/constraint ["']([^"']+)["']/i)?.[1] ?? null;
  const profilePhone = extractProfilePhoneFromDetail(detail);
  return JSON.stringify({
    errorCode: body.code ?? body.error_code ?? null,
    constraint,
    requestedPhone: maskedPhoneShape(requestedPhone, requestedPhone),
    profilePhone: maskedPhoneShape(profilePhone, requestedPhone),
    postgresDetailLength: detail.length,
  });
}

export function assertLocalSupabaseApiUrl(raw) {
  if (typeof raw !== "string" || raw.trim() === "" || raw !== raw.trim() || [...raw].some((c) => c.charCodeAt(0) <= 32 || c.charCodeAt(0) === 127)) {
    throw new Error("SUPABASE_URL must be an explicit local URL");
  }
  let u;
  try { u = new URL(raw); } catch { throw new Error("SUPABASE_URL is malformed"); }
  if (u.protocol !== "http:" || !LOCAL_SUPABASE_API_HOSTS.has(u.hostname)
      || u.port !== "54321" || u.username || u.password || u.pathname !== "/" || u.search || u.hash) {
    throw new Error("REFUSING non-local Supabase API target; allowed API targets are localhost aliases on port 54321");
  }
  return u.origin;
}

export function buildCreatePhoneUserRequest(supabaseUrl, serviceRoleKey, account, password) {
  const base = assertLocalSupabaseApiUrl(supabaseUrl);
  if (!isValidE164Phone(account?.phone)) throw new Error("Invalid E.164 phone for synthetic seed account");
  return {
    url: `${base}/auth/v1/admin/users`,
    init: {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` },
      body: JSON.stringify({
        phone: account.phone,
        password,
        phone_confirm: true,
        user_metadata: { full_name: account.full_name, synthetic_seed: true, seed_key: account.seed_key },
      }),
    },
  };
}

const allAccounts = (data) => [...data.students, ...data.faculty, ...data.administrators];

async function listLocalAuthUsers(base, key, fetchImpl) {
  const users = [];
  for (let page = 1; page <= 10; page += 1) {
    const res = await fetchImpl(`${base}/auth/v1/admin/users?page=${page}&per_page=1000`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    });
    if (!res.ok) throw new Error(`Local Auth Admin list failed: HTTP ${res.status}`);
    const body = await res.json();
    const pageUsers = Array.isArray(body) ? body : body?.users;
    if (!Array.isArray(pageUsers)) throw new Error("Unexpected local Auth Admin users response");
    users.push(...pageUsers);
    if (pageUsers.length < 1000) return users;
  }
  throw new Error("Local Auth users exceed bounded pagination limit");
}

export async function provisionUniversityAccounts({ supabaseUrl, serviceRoleKey, password, accounts, fetchImpl = fetch }) {
  // Reject a remote URL before the first fetch (including Auth Admin list calls).
  const base = assertLocalSupabaseApiUrl(supabaseUrl);
  if (!serviceRoleKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required");
  if (typeof password !== "string" || password.length < 12) throw new Error("Set DEMO_PASSWORD (minimum 12 characters)");
  const desired = allAccounts(accounts);
  if (desired.length !== 40) throw new Error(`Expected 40 synthetic accounts, received ${desired.length}`);

  const existing = new Map();
  for (const user of await listLocalAuthUsers(base, serviceRoleKey, fetchImpl)) {
    if (!user.phone) continue;
    if (existing.has(user.phone)) throw new Error(`Duplicate local Auth phone ${user.phone}`);
    existing.set(user.phone, user);
  }

  let created = 0, reused = 0;
  for (const account of desired) {
    const previous = existing.get(account.phone);
    if (previous) {
      const metadata = previous.user_metadata ?? previous.raw_user_meta_data ?? {};
      if (previous.email || metadata.synthetic_seed !== true || metadata.seed_key !== account.seed_key) {
        throw new Error(`Refusing to reuse an Auth account that does not match ${account.seed_key}`);
      }
      reused += 1;
      continue;
    }
    const req = buildCreatePhoneUserRequest(base, serviceRoleKey, account, password);
    const res = await fetchImpl(req.url, req.init);
    if (!res.ok) {
      const responseText = await res.text();
      const diagnostics = summarizeAuthCreateFailure(responseText, account.phone);
      throw new Error("Local Auth create failed for " + account.seed_key + ": HTTP " + res.status + " " + diagnostics);
    }
    const body = await res.json();
    const user = body?.user ?? body;
    if (!user?.id || user.phone !== account.phone || user.email) {
      throw new Error(`Auth Admin did not create a phone-only account for ${account.seed_key}`);
    }
    existing.set(account.phone, user);
    created += 1;
  }
  return { created, reused, total: desired.length };
}

async function main() {
  const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, DEMO_PASSWORD } = process.env;
  // Do this before reading credentials or making any network call.
  assertLocalSupabaseApiUrl(SUPABASE_URL);
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  const accounts = JSON.parse(readFileSync(join(root, "fixtures", "university-accounts.json"), "utf8"));
  const result = await provisionUniversityAccounts({
    supabaseUrl: SUPABASE_URL, serviceRoleKey: SUPABASE_SERVICE_ROLE_KEY,
    password: DEMO_PASSWORD, accounts,
  });
  console.log(`Synthetic university Auth accounts: created=${result.created}, reused=${result.reused}, total=${result.total}`);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.message); process.exit(1); });
