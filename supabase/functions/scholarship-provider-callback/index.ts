import { createClient } from "npm:@supabase/supabase-js@2";
import {
  parseScholarshipProviderConfigs,
  readBoundedTextStream,
  sha256Hex,
  verifyProviderWebhookSignature,
} from "../_shared/scholarship-provider.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const PROVIDER_KEY = /^[A-Z0-9][A-Z0-9_-]{1,63}$/;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  let rawBody: string;
  try {
    rawBody = await readBoundedTextStream(req.body, 16 * 1024);
  } catch {
    return json({ error: "REQUEST_BODY_TOO_LARGE" }, 413);
  }
  if (!rawBody) return json({ error: "INVALID_REQUEST" }, 400);

  const timestamp = req.headers.get("X-Alumni-Timestamp") ?? "";
  const signature = req.headers.get("X-Alumni-Signature") ?? "";
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  if (
    !parsed || typeof parsed !== "object" || Array.isArray(parsed) ||
    Object.keys(parsed).some((key) =>
      !["provider_key", "event_id", "application_reference", "status", "note"].includes(key)
    )
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const body = parsed as Record<string, unknown>;
  if (
    typeof body.provider_key !== "string" || !PROVIDER_KEY.test(body.provider_key) ||
    typeof body.event_id !== "string" || body.event_id.trim().length < 1 || body.event_id.length > 200 ||
    typeof body.application_reference !== "string" ||
      body.application_reference.trim().length < 1 || body.application_reference.length > 200 ||
    !["IN_REVIEW", "ACCEPTED", "REJECTED"].includes(String(body.status)) ||
    (body.note !== undefined && body.note !== null &&
      (typeof body.note !== "string" || body.note.length > 2000))
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  let providerConfig;
  try {
    const providers = parseScholarshipProviderConfigs(Deno.env.get("SCHOLARSHIP_PROVIDERS_JSON"));
    providerConfig = providers[body.provider_key];
  } catch {
    return json({ error: "PROVIDER_CONFIGURATION_UNAVAILABLE" }, 503);
  }
  if (!providerConfig) return json({ error: "UNKNOWN_PROVIDER" }, 401);

  const signatureValid = await verifyProviderWebhookSignature(
    providerConfig.webhook_secret,
    timestamp,
    signature,
    rawBody,
  );
  if (!signatureValid) return json({ error: "INVALID_PROVIDER_SIGNATURE" }, 401);

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const digest = await sha256Hex(rawBody);
  const { data: result, error } = await admin.rpc("process_scholarship_provider_event", {
    p_provider_key: body.provider_key,
    p_event_id: body.event_id.trim(),
    p_provider_reference: body.application_reference.trim(),
    p_new_status: body.status,
    p_note: body.note ?? null,
    p_payload_digest: digest,
  });

  if (error) {
    const message = error.message ?? "";
    const status = message.includes("SCHOLARSHIP_PROVIDER_REFERENCE_NOT_FOUND") ? 404
      : message.includes("INVALID_SCHOLARSHIP_STATUS_TRANSITION") ||
          message.includes("PROVIDER_EVENT_ID_CONFLICT") ? 409
      : message.includes("INVALID_INPUT") ? 400
      : 503;
    return json({
      error: status === 503 ? "PROVIDER_EVENT_PROCESSING_FAILED" : message,
    }, status);
  }
  return json({ accepted: true, result }, 200);
});
