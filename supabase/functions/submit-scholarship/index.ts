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
  if (!url || !anonKey || !serviceKey) {
    return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  }
  if (!authorization.startsWith("Bearer ")) return json({ error: "UNAUTHENTICATED" }, 401);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return json({ error: "UNAUTHENTICATED" }, 401);

  const body = await req.json().catch(() => null);
  const allowed = ["p_opportunity_id", "p_cv_document_id", "p_personal_statement", "p_application_data"];
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).some((key) => !allowed.includes(key)) ||
    typeof body.p_opportunity_id !== "string" || !UUID.test(body.p_opportunity_id) ||
    (body.p_cv_document_id !== undefined &&
      body.p_cv_document_id !== null &&
      (typeof body.p_cv_document_id !== "string" || !UUID.test(body.p_cv_document_id))) ||
    (body.p_personal_statement !== undefined &&
      body.p_personal_statement !== null &&
      typeof body.p_personal_statement !== "string") ||
    (body.p_application_data !== undefined &&
      (body.p_application_data === null ||
       typeof body.p_application_data !== "object" ||
       Array.isArray(body.p_application_data)))
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const { data: applicationData, error: applicationError } = await userClient.rpc(
    "apply_for_scholarship",
    {
      p_opportunity_id: body.p_opportunity_id,
      p_cv_document_id: body.p_cv_document_id ?? null,
      p_personal_statement: body.p_personal_statement ?? null,
      p_application_data: body.p_application_data ?? {},
    },
  );
  if (applicationError) {
    const message = applicationError.message ?? "APPLICATION_SUBMISSION_FAILED";
    const status = message.includes("ALREADY_APPLIED") ? 409
      : message.includes("OPPORTUNITY_NOT_FOUND") ? 404
      : message.includes("NOT_A_SCHOLARSHIP") || message.includes("OPPORTUNITY_CLOSED") ||
          message.includes("NOT_ELIGIBLE") || message.includes("INVALID_INPUT") ? 422
      : message.includes("CV_NOT_FOUND") ? 404
      : 500;
    return json({
      error: status === 500 ? "APPLICATION_SUBMISSION_FAILED" : message,
      details: applicationError.details ?? null,
    }, status);
  }

  const application = Array.isArray(applicationData) ? applicationData[0] : applicationData;
  if (!application?.id || !UUID.test(application.id)) {
    return json({ error: "APPLICATION_SUBMISSION_FAILED" }, 500);
  }

  if (application.status === "INTERNAL_ONLY") {
    return json({
      application_id: application.id,
      status: application.status,
      delivery_status: application.delivery_status,
      external_submission: false,
    }, 200);
  }

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  let delivery;
  try {
    const results = await deliverScholarshipApplications(admin, {
      applicationId: application.id,
      limit: 1,
    });
    delivery = results.find((item) => item.application_id === application.id) ?? null;
  } catch {
    // The application and outbox were committed transactionally. A scheduler or administrator
    // can safely resume delivery later; never report it as externally submitted here.
    return json({
      application_id: application.id,
      status: "PENDING_DELIVERY",
      delivery_status: "PENDING",
      external_submission: false,
      message: "APPLICATION_SAVED_DELIVERY_PENDING",
    }, 202);
  }

  if (!delivery) {
    return json({
      application_id: application.id,
      status: "PENDING_DELIVERY",
      delivery_status: application.delivery_status ?? "PENDING",
      external_submission: false,
    }, 202);
  }

  return json({
    application_id: application.id,
    status: delivery.status,
    delivery_status: delivery.delivery_status,
    external_submission: delivery.status === "SUBMITTED_EXTERNALLY",
    provider_application_reference: delivery.provider_application_reference ?? null,
    delivery_error: delivery.error_code ?? null,
  }, delivery.status === "SUBMITTED_EXTERNALLY" ? 200 : 202);
});
