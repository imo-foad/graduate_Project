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
  const { data: isAdmin, error: adminCheckError } = await userClient.rpc("assert_platform_admin");
  if (adminCheckError || isAdmin !== true) return json({ error: "ADMIN_REQUIRED" }, 403);

  const body = await req.json().catch(() => null);
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).some((key) => key !== "request_id") ||
    typeof body.request_id !== "string" || !UUID.test(body.request_id)
  ) return json({ error: "INVALID_REQUEST" }, 400);

  const adminClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: targetId, error: approvalError } = await adminClient.rpc(
    "get_approved_account_deletion",
    { p_request_id: body.request_id },
  );
  if (approvalError || typeof targetId !== "string") {
    const message = approvalError?.message ?? "";
    if (message.includes("COMPANY_OWNERSHIP_TRANSFER_REQUIRED")) {
      return json({ error: "COMPANY_OWNERSHIP_TRANSFER_REQUIRED" }, 409);
    }
    if (message.includes("COMPANY_OWNERSHIP_TRANSFER_REQUIRED") ||
        message.includes("COMPANY_OWNERSHIP_TRANSFER_REQUIRED")) {
      return json({ error: "COMPANY_OWNERSHIP_TRANSFER_REQUIRED" }, 409);
    }
    if (message.includes("ADMIN_ACCOUNT_REQUIRES_MANUAL_TRANSFER")) {
      return json({ error: "ADMIN_ACCOUNT_REQUIRES_MANUAL_TRANSFER" }, 409);
    }
    if (message.includes("APPROVED_ACCOUNT_DELETION_NOT_FOUND")) {
      return json({ error: "APPROVED_ACCOUNT_DELETION_NOT_FOUND" }, 404);
    }
    console.error("approved account deletion lookup failed", { code: approvalError?.code });
    return json({ error: "ACCOUNT_DELETION_PRECHECK_FAILED" }, 503);
  }

  const { data: cvRows, error: cvReadError } = await adminClient
    .from("cv_documents")
    .select("storage_path")
    .eq("graduate_id", targetId);
  if (cvReadError) {
    console.error("CV storage cleanup lookup failed", { code: cvReadError.code });
    return json({ error: "ACCOUNT_DELETION_PRECHECK_FAILED" }, 503);
  }

  const paths = (cvRows ?? []).map((row) => row.storage_path);
  if (paths.some((path) => typeof path !== "string" || !path.startsWith(targetId + "/"))) {
    console.error("CV storage path ownership mismatch during account deletion");
    return json({ error: "CV_STORAGE_OWNERSHIP_MISMATCH" }, 409);
  }
  if (paths.length > 0) {
    const { error: storageError } = await adminClient.storage.from("cv-documents").remove(paths);
    if (storageError) {
      console.error("CV storage cleanup failed", { message: storageError.message });
      return json({ error: "CV_STORAGE_CLEANUP_FAILED" }, 503);
    }
  }

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(targetId);
  if (deleteError) {
    console.error("Auth account deletion failed after CV cleanup", { status: deleteError.status });
    return json({ error: "AUTH_ACCOUNT_DELETION_FAILED" }, 503);
  }

  // The BEFORE DELETE Auth trigger atomically marks the approved request COMPLETED and
  // appends an audit event. All user-owned rows cascade; CV objects were removed above.
  return json({ request_id: body.request_id, status: "COMPLETED" }, 200);
});
