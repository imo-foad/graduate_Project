// Phone-first registration (Phase 2).
//
// Request: { national_id, phone, password, full_name }
// Flow: institutional identity verification -> create a phone Auth user -> record the keyed digest and
// verified identities -> send the mandatory phone OTP. The account stays PENDING_VERIFICATION until the
// client confirms the OTP (Supabase Auth) and calls /functions/v1/finalize-registration.
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

  const verification = await provider.verify({ nationalId, phone });
  if (!verification.verified) {
    return json({ error: verification.error_code ?? "IDENTITY_NOT_VERIFIED" }, 422);
  }
  const digest = await nationalIdDigest(digestSecret, nationalId);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const created = await admin.auth.admin.createUser({
    phone,
    password: input.password,
    phone_confirm: false,
    user_metadata: { full_name: (verification.display_name?.trim() || input.full_name.trim()).slice(0, 200) },
  });
  if (created.error || !created.data.user) {
    // Do not echo the provider/Auth error message: it can contain the phone number.
    const already = /already|registered|exists/i.test(created.error?.message ?? "");
    return json({ error: already ? "PHONE_ALREADY_REGISTERED" : "AUTH_USER_CREATE_FAILED" }, already ? 409 : 500);
  }
  const userId = created.data.user.id;
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
    // Roll back the Auth user so the phone can be registered again once the conflict is resolved.
    await admin.auth.admin.deleteUser(userId).catch(() => undefined);
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
