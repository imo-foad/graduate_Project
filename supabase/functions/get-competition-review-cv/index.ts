import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization") ?? "";
  if (!url || !anonKey || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  if (!authorization.startsWith("Bearer ")) return json({ error: "UNAUTHENTICATED" }, 401);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "UNAUTHENTICATED" }, 401);

  const body = await req.json().catch(() => null);
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).length !== 1 ||
    typeof body.application_id !== "string" || !UUID.test(body.application_id)
  ) return json({ error: "INVALID_REQUEST" }, 400);

  const { data: path, error: authorizationError } = await userClient.rpc(
    "get_competition_review_cv_path",
    { p_application_id: body.application_id },
  );
  if (authorizationError) {
    const message = authorizationError.message ?? "";
    const status = message.includes("COMPETITION_APPLICATION_NOT_FOUND") ? 404
      : message.includes("COMPETITION_APPLICATION_NOT_REVIEWABLE") ? 409
      : message.includes("COMPETITION_REVIEWER_REQUIRED") ? 403
      : message.includes("INVALID_INPUT") ? 400
      : 503;
    return json({ error: status === 503 ? "CV_REVIEW_AUTHORIZATION_FAILED" : message }, status);
  }
  if (path === null) return json({ application_id: body.application_id, cv_available: false }, 200);
  if (typeof path !== "string" || path.includes("..")) {
    return json({ error: "CV_STORAGE_PATH_INVALID" }, 409);
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: signed, error: signError } = await admin.storage
    .from("cv-documents")
    .createSignedUrl(path, 600);
  if (signError || !signed?.signedUrl) {
    console.error("reviewer CV signed URL creation failed", { code: signError?.name });
    return json({ error: "CV_SIGNED_URL_UNAVAILABLE" }, 503);
  }
  return json({
    application_id: body.application_id,
    cv_available: true,
    download_url: signed.signedUrl,
    expires_in_seconds: 600,
  }, 200);
});
