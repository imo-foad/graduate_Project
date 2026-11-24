// Creates the synthetic Graduate demo accounts through the Auth Admin API (no public sign-up).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (server-side secret), DEMO_PASSWORD (>= 12 chars). Never commit them.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export function buildCreateUserRequest(url, serviceKey, user, password) {
  return {
    url: `${url.replace(/\/$/, "")}/auth/v1/admin/users`,
    init: {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
      body: JSON.stringify({ email: user.email, password, email_confirm: true, user_metadata: { full_name: user.full_name } }),
    },
  };
}

async function main() {
  const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, DEMO_PASSWORD } = process.env;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) throw new Error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
  if (!DEMO_PASSWORD || DEMO_PASSWORD.length < 12) throw new Error("Set DEMO_PASSWORD (min 12 chars)");
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  const users = JSON.parse(readFileSync(join(root, "fixtures", "demo-profiles.json"), "utf8"));
  console.log(`Target: ${SUPABASE_URL}`);
  for (const u of users) {
    const { url, init } = buildCreateUserRequest(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, u, DEMO_PASSWORD);
    const res = await fetch(url, init);
    const text = await res.text();
    if (res.ok) console.log(`created ${u.email}`);
    else if (res.status === 422 && /already|registered|exists/i.test(text)) console.log(`exists  ${u.email}`);
    else throw new Error(`${u.email}: HTTP ${res.status} ${text}`);
  }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.message); process.exit(1); });
