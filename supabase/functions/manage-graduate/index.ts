import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization") ?? "";
  if (!url || !anonKey || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  if (!authorization.startsWith("Bearer ")) return json({ error: "UNAUTHENTICATED" }, 401);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "UNAUTHENTICATED" }, 401);
  const actorId = authData.user.id;
  const { data: isAdmin, error: adminCheckError } = await userClient.rpc("assert_platform_admin");
  if (adminCheckError || isAdmin !== true) return json({ error: "ADMIN_REQUIRED" }, 403);

  const body = await req.json().catch(() => null);
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).some((key) => !["user_id", "action", "reason"].includes(key)) ||
    typeof body.user_id !== "string" || !UUID.test(body.user_id) ||
    !["SUSPEND", "REACTIVATE"].includes(body.action) ||
    typeof body.reason !== "string" || body.reason.trim().length < 8 || body.reason.trim().length > 1000
  ) return json({ error: "INVALID_REQUEST" }, 400);

  const adminClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const targetId = body.user_id;
  const status = body.action === "SUSPEND" ? "SUSPENDED" : "ACTIVE";
  const rpcArgs = {
    p_actor_id: actorId,
    p_user_id: targetId,
    p_status: status,
    p_reason: body.reason.trim(),
  };

  if (body.action === "SUSPEND") {
    // Database suspension is applied first. Restrictive RLS and _require_uid deny existing JWTs.
    const { error: dbError } = await adminClient.rpc("set_graduate_account_status_for_admin", rpcArgs);
    if (dbError) {
      if (dbError.message?.includes("REVOKE_ADMIN_BEFORE_ACCOUNT_CHANGE")) {
        return json({ error: "REVOKE_ADMIN_BEFORE_ACCOUNT_CHANGE" }, 409);
      }
      if (dbError.message?.includes("USER_NOT_FOUND")) return json({ error: "USER_NOT_FOUND" }, 404);
      console.error("graduate suspension database update failed", { code: dbError.code });
      return json({ error: "ACCOUNT_STATUS_UPDATE_FAILED" }, 503);
    }
    const { error: banError } = await adminClient.auth.admin.updateUserById(
      targetId, { ban_duration: "876000h" },
    );
    if (banError) {
      console.error("Auth ban failed after database suspension", { status: banError.status });
      return json({ error: "ACCOUNT_SUSPENDED_AUTH_BAN_PENDING" }, 503);
    }
  } else {
    // Keep the profile suspended while Auth is unbanned. If the DB transition fails, re-ban.
    const { error: unbanError } = await adminClient.auth.admin.updateUserById(
      targetId, { ban_duration: "none" },
    );
    if (unbanError) {
      console.error("Auth unban failed", { status: unbanError.status });
      return json({ error: "ACCOUNT_REACTIVATION_FAILED" }, 503);
    }
    const { error: dbError } = await adminClient.rpc("set_graduate_account_status_for_admin", rpcArgs);
    if (dbError) {
      const { error: rebanError } = await adminClient.auth.admin.updateUserById(
        targetId, { ban_duration: "876000h" },
      );
      if (rebanError) console.error("critical: failed to restore Auth ban after DB reactivation failure");
      if (dbError.message?.includes("REVOKE_ADMIN_BEFORE_ACCOUNT_CHANGE")) {
        return json({ error: "REVOKE_ADMIN_BEFORE_ACCOUNT_CHANGE" }, 409);
      }
      console.error("graduate reactivation database update failed", { code: dbError.code });
      return json({ error: "ACCOUNT_REACTIVATION_FAILED" }, 503);
    }
  }
  return json({ user_id: targetId, account_status: status }, 200);
});
