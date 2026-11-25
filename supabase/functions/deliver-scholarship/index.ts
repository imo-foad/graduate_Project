import { createClient } from "npm:@supabase/supabase-js@2";
import { deliverScholarshipApplications } from "../_shared/scholarship-delivery.ts";

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

  const body = await req.json().catch(() => null);
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).some((key) => !["application_id", "limit"].includes(key)) ||
    (body.application_id !== undefined &&
      (typeof body.application_id !== "string" || !UUID.test(body.application_id))) ||
    (body.limit !== undefined &&
      (!Number.isInteger(body.limit) || body.limit < 1 || body.limit > 50))
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const isServiceRole = authorization.slice("Bearer ".length) === serviceKey;
  if (!isServiceRole) {
    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "UNAUTHENTICATED" }, 401);

    const { data: isAdmin, error: adminError } = await userClient.rpc("assert_scholarship_admin");
    if (adminError || isAdmin !== true) return json({ error: "ADMIN_REQUIRED" }, 403);
    if (!body.application_id) {
      return json({ error: "APPLICATION_ID_REQUIRED_FOR_ADMIN_RETRY" }, 400);
    }

    const { error: retryError } = await userClient.rpc("retry_scholarship_delivery", {
      p_application_id: body.application_id,
    });
    if (retryError) {
      const message = retryError.message ?? "";
      const status = message.includes("SCHOLARSHIP_APPLICATION_NOT_FOUND") ? 404
        : message.includes("SCHOLARSHIP_PROVIDER_NOT_CONFIGURED") ||
            message.includes("SCHOLARSHIP_DELIVERY_IN_PROGRESS") ||
            message.includes("SCHOLARSHIP_DELIVERY_NOT_RETRYABLE") ? 409
        : 500;
      return json({
        error: status === 500 ? "SCHOLARSHIP_RETRY_QUEUE_FAILED" : message,
      }, status);
    }
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  try {
    const results = await deliverScholarshipApplications(admin, {
      applicationId: body.application_id ?? null,
      limit: body.limit ?? 10,
    });
    return json({
      processed: results.length,
      results,
    }, 200);
  } catch {
    return json({ error: "SCHOLARSHIP_DELIVERY_WORKER_FAILED" }, 503);
  }
});
