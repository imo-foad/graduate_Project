// Phone-first registration (Phase 2).
//
// Request: { national_id, phone, password, full_name }
// Flow: institutional identity verification -> create or safely resume the exact pending phone account ->
// record the keyed digest and verified identities -> send the mandatory phone OTP. Re-submitting the same
// phone + National-ID pair can resend OTP after a partial failure without creating an account alias. The
// account stays PENDING_VERIFICATION until Auth confirms OTP and /functions/v1/finalize-registration runs.
//
// The National ID is never logged, echoed, stored in plaintext, or used as a credential. The institutional
// provider is external: when it is not configured this endpoint returns 503 IDENTITY_PROVIDER_UNAVAILABLE
// and does not invent a successful verification.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  createIdentityProviderFromEnv, IdentityInputError, nationalIdDigest, normalizeNationalId, normalizePhone,
} from "../_shared/identity-provider.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_KEYS = new Set(["national_id", "phone", "password", "full_name"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const digestSecret = env("NATIONAL_ID_HMAC_SECRET");
  if (!url || !anonKey || !serviceKey || digestSecret.length < 32) {
    return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)
      || Object.keys(body).some((key) => !ALLOWED_KEYS.has(key))) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const input = body as Record<string, unknown>;
  let nationalId: string, phone: string;
  try {
    nationalId = normalizeNationalId(input.national_id);
    phone = normalizePhone(input.phone);
  } catch (error) {
    if (error instanceof IdentityInputError) return json({ error: error.code }, 422);
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  if (typeof input.password !== "string" || input.password.length < 10 || input.password.length > 128) {
    return json({ error: "WEAK_PASSWORD" }, 422);
  }
  if (typeof input.full_name !== "string" || input.full_name.trim().length < 2 || input.full_name.length > 200) {
    return json({ error: "INVALID_FULL_NAME" }, 422);
  }

  const digest = await nationalIdDigest(digestSecret, nationalId);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // Fast path: an exact pending identity already passed the institutional check. OTP resend must
  // remain possible even while the institution's API is temporarily unavailable.
  const pendingRetry = await admin.rpc("find_pending_registration_retry", {
    p_phone: phone,
    p_national_id_digest: digest,
  });
  if (pendingRetry.error) {
    return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
  }
  if (typeof pendingRetry.data === "string" && UUID_RE.test(pendingRetry.data)) {
    const existingIdentities = await admin.from("human_identities")
      .select("identity_type")
      .eq("profile_id", pendingRetry.data)
      .eq("status", "VERIFIED");
    if (existingIdentities.error) {
      return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
    }

    const anon = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const otp = await anon.auth.signInWithOtp({ phone, options: { shouldCreateUser: false } });
    if (otp.error) return json({ error: "OTP_DELIVERY_FAILED" }, 503);

    return json({
      status: "PENDING_OTP",
      identities: (existingIdentities.data ?? []).map((identity) => identity.identity_type),
      next: "Confirm the phone OTP, then POST /functions/v1/finalize-registration with the new access token.",
    }, 202);
  }

  const provider = createIdentityProviderFromEnv({
    IDENTITY_PROVIDER_MODE: env("IDENTITY_PROVIDER_MODE"),
    IDENTITY_PROVIDER_URL: env("IDENTITY_PROVIDER_URL"),
    IDENTITY_PROVIDER_TOKEN: env("IDENTITY_PROVIDER_TOKEN"),
    ALLOW_MOCK_IDENTITY: env("ALLOW_MOCK_IDENTITY"),
  });
  if (!provider) {
    // BLOCKED_EXTERNAL: no approved institutional provider/credentials were supplied.
    return json({ error: "IDENTITY_PROVIDER_UNAVAILABLE" }, 503);
  }
  const verification = await provider.verify({ nationalId, phone });
  if (!verification.verified) {
    return json({ error: verification.error_code ?? "IDENTITY_NOT_VERIFIED" }, 422);
  }
  const created = await admin.auth.admin.createUser({
    phone,
    password: input.password,
    phone_confirm: false,
    user_metadata: { full_name: (verification.display_name?.trim() || input.full_name.trim()).slice(0, 200) },
  });

  let userId: string;
  let createdNewUser = false;
  if (!created.error && created.data.user) {
    userId = created.data.user.id;
    createdNewUser = true;
  } else {
    // A prior request may have created the pending phone account but lost the OTP response, or OTP
    // delivery may have failed. Only the exact phone + keyed National-ID pair may resume that account.
    // Active accounts, phone collisions and identities linked elsewhere remain non-recoverable here.
    const already = /already|registered|exists/i.test(created.error?.message ?? "");
    if (!already) return json({ error: "AUTH_USER_CREATE_FAILED" }, 500);

    const pending = await admin.rpc("find_pending_registration_retry", {
      p_phone: phone,
      p_national_id_digest: digest,
    });
    if (pending.error) {
      return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
    }
    if (typeof pending.data !== "string" || !UUID_RE.test(pending.data)) {
      return json({ error: "PHONE_ALREADY_REGISTERED" }, 409);
    }
    userId = pending.data;
  }

  if (!UUID_RE.test(userId)) {
    return json({ error: "AUTH_USER_CREATE_FAILED" }, 500);
  }

  const recorded = await admin.rpc("record_identity_verification", {
    p_profile_id: userId,
    p_provider: verification.provider,
    p_provider_reference: verification.provider_reference,
    p_national_id_digest: digest,
    p_national_id_last4: nationalId.slice(-4),
    p_identities: verification.identities,
    p_status: "VERIFIED",
    p_error_code: null,
    p_attributes: { display_name_verified: true },
  });
  if (recorded.error) {
    // Delete only an Auth user created in this request. Never destroy a prior pending account on retry.
    if (createdNewUser) await admin.auth.admin.deleteUser(userId).catch(() => undefined);
    const linked = /IDENTITY_ALREADY_LINKED/.test(recorded.error.message ?? "");
    return json({ error: linked ? "IDENTITY_ALREADY_LINKED" : "IDENTITY_RECORD_FAILED" }, linked ? 409 : 500);
  }

  const anon = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const otp = await anon.auth.signInWithOtp({ phone, options: { shouldCreateUser: false } });
  if (otp.error) {
    // The account remains PENDING; the client can retry the OTP step. Do not delete the verified account.
    return json({ error: "OTP_DELIVERY_FAILED" }, 503);
  }

  return json({
    status: "PENDING_OTP",
    identities: verification.identities.map((identity) => identity.identity_type),
    next: "Confirm the phone OTP, then POST /functions/v1/finalize-registration with the new access token.",
  }, 202);
});
