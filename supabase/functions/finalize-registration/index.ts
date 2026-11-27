// Completes phone-first registration after the client confirms the Supabase phone OTP.
// The database checks BOTH conditions: auth.users.phone_confirmed_at is set AND at least one verified
// institutional identity exists. Only then does account_status move to ACTIVE.
import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const authorization = req.headers.get("Authorization") ?? "";
  if (!url || !anonKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  if (!authorization.startsWith("Bearer ")) return json({ error: "UNAUTHENTICATED" }, 401);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "UNAUTHENTICATED" }, 401);

  const { data, error } = await userClient.rpc("finalize_registration");
  if (error) {
    const message = error.message ?? "";
    if (message.includes("PHONE_NOT_VERIFIED")) return json({ error: "PHONE_NOT_VERIFIED" }, 409);
    if (message.includes("IDENTITY_NOT_VERIFIED")) return json({ error: "IDENTITY_NOT_VERIFIED" }, 409);
    if (message.includes("ACCOUNT_UNAVAILABLE")) return json({ error: "ACCOUNT_UNAVAILABLE" }, 403);
    return json({ error: "REGISTRATION_FINALIZE_FAILED" }, 500);
  }
  return json(data, 200);
});
