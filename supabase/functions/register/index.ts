// Email-confirmed registration against the local synthetic identity registry (demo MVP).
//
// Request: { email, phone?, password, full_name, synthetic_id }
// Flow:
//   1. validate the request and normalize the fake SYNTH- identifier;
//   2. resolve it in the private local registry (unknown/real National IDs are rejected);
//   3. create or safely resume the exact PENDING account for this email + digest;
//   4. associate the synthetic identities with the account;
//   5. request Supabase email confirmation and keep the account PENDING_VERIFICATION.
//
// The client confirms the email through Supabase Auth, then calls /functions/v1/finalize-registration.
// No SMS/OTP is requested. Phone is optional contact data and is never an Auth identifier here.
//
// Auth accepting a confirmation request is not proof of delivery. The response therefore reports
// `email_confirmation: "REQUESTED"` and `email_delivery: "UNCONFIRMED"`; it never claims the email
// was delivered. The synthetic registry is local demo data, not institutional verification.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  lastFourDigits, normalizeEmail, normalizeOptionalPhone, normalizeSyntheticId,
  RegistrationInputError, SYNTHETIC_PROVIDER, SYNTHETIC_VERIFICATION_SOURCE,
  syntheticIdentityDigest, validateFullName, validatePassword, validatedIdentities,
} from "../_shared/synthetic-identity.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_KEYS = new Set(["email", "phone", "password", "full_name", "synthetic_id", "resend_confirmation"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)
      || Object.keys(body).some((key) => !ALLOWED_KEYS.has(key))) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }
  const input = body as Record<string, unknown>;
  const resendConfirmation = input.resend_confirmation === undefined ? false : input.resend_confirmation;
  if (typeof resendConfirmation !== "boolean") {
    return json({ error: "INVALID_RESEND_CONFIRMATION" }, 422);
  }

  let email: string, phone: string | null, syntheticId: string, password: string, fullName: string;
  try {
    email = normalizeEmail(input.email);
    phone = normalizeOptionalPhone(input.phone);
    syntheticId = normalizeSyntheticId(input.synthetic_id);
    password = validatePassword(input.password);
    fullName = validateFullName(input.full_name);
  } catch (error) {
    if (error instanceof RegistrationInputError) return json({ error: error.code }, 422);
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const digest = await syntheticIdentityDigest(syntheticId);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // 1. Resolve the synthetic identity before creating any Auth user.
  const resolved = await admin.rpc("resolve_synthetic_identity", { p_lookup_digest: digest });
  if (resolved.error) return json({ error: "SYNTHETIC_REGISTRY_UNAVAILABLE" }, 503);
  const record = resolved.data as Record<string, unknown> | null;
  if (!record || record.found !== true) {
    return json({ error: "SYNTHETIC_IDENTITY_NOT_FOUND" }, 422);
  }
  let identities;
  try {
    identities = validatedIdentities(record.identities);
  } catch (error) {
    if (error instanceof RegistrationInputError) return json({ error: error.code }, 500);
    return json({ error: "SYNTHETIC_REGISTRY_UNAVAILABLE" }, 503);
  }
  const displayName = typeof record.display_name === "string" && record.display_name.trim().length >= 2
    ? record.display_name.trim()
    : fullName;

  // 2. Resume only the exact pending email + digest pair. This also covers a retry after a lost
  //    confirmation-email response without creating an account alias.
  const pending = await admin.rpc("find_pending_email_registration_retry", {
    p_email: email,
    p_lookup_digest: digest,
  });
  if (pending.error) return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
  let userId: string | null = typeof pending.data === "string" && UUID_RE.test(pending.data)
    ? pending.data
    : null;
  let needsIdentityAssociation = !userId;
  let createdNewUser = false;

  // 3. Create the pending email account only when no matching pending account exists.
  if (!userId) {
    if (phone) {
      const phoneOwner = await admin.from("profiles").select("id").eq("phone", phone).maybeSingle();
      if (phoneOwner.error) return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
      if (phoneOwner.data) return json({ error: "PHONE_ALREADY_REGISTERED" }, 409);
    }

    const created = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: false,
      // app_metadata is writable only by trusted Auth Admin operations. The digest binds an
      // orphaned Auth user to the exact synthetic identity if creation succeeded but the request
      // lost its response before the verification ledger was written.
      app_metadata: { registration_synthetic_digest: digest },
      user_metadata: {
        full_name: displayName.slice(0, 200),
        registration_flow: "EMAIL_IDENTITY_VERIFICATION",
        ...(phone ? { contact_phone: phone } : {}),
      },
    });

    if (!created.error && created.data.user) {
      userId = created.data.user.id;
      createdNewUser = true;
    } else {
      // A prior request may have created the pending account but lost the response. Recover only
      // the exact email + digest pair, or an Auth-created pending profile with no ledger row yet.
      const retry = await admin.rpc("find_pending_email_registration_retry", {
        p_email: email,
        p_lookup_digest: digest,
      });
      if (retry.error) return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
      if (typeof retry.data === "string" && UUID_RE.test(retry.data)) {
        userId = retry.data;
        needsIdentityAssociation = false;
      } else {
        const unlinked = await admin.rpc("find_unlinked_pending_email_registration_retry", {
          p_email: email,
          p_lookup_digest: digest,
        });
        if (unlinked.error) return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
        if (typeof unlinked.data === "string" && UUID_RE.test(unlinked.data)) {
          userId = unlinked.data;
          needsIdentityAssociation = true;
        } else {
          if (phone) {
            const phoneOwner = await admin.from("profiles").select("id").eq("phone", phone).maybeSingle();
            if (phoneOwner.data) return json({ error: "PHONE_ALREADY_REGISTERED" }, 409);
          }
          return json({ error: "EMAIL_ALREADY_REGISTERED" }, 409);
        }
      }
    }
  }

  if (!userId || !UUID_RE.test(userId)) {
    return json({ error: "AUTH_USER_CREATE_FAILED" }, 500);
  }

  // 4. Associate identities only for a new account or a recovered pre-ledger orphan. An exact
  //    pending retry already has the identity-verification row, so replaying the upsert would add
  //    duplicate audit events and mutate verification timestamps unnecessarily.
  if (needsIdentityAssociation) {
    const recorded = await admin.rpc("record_identity_verification", {
      p_profile_id: userId,
      p_provider: SYNTHETIC_PROVIDER,
      p_provider_reference: null,
      p_national_id_digest: digest,
      p_national_id_last4: lastFourDigits(syntheticId),
      p_identities: identities,
      p_status: "VERIFIED",
      p_error_code: null,
      p_attributes: { synthetic_registry: true, display_name_verified: true },
      p_verification_source: SYNTHETIC_VERIFICATION_SOURCE,
    });
    if (recorded.error) {
      // Delete only an Auth user created in this request. Never destroy a prior pending account.
      if (createdNewUser) await admin.auth.admin.deleteUser(userId).catch(() => undefined);
      const linked = /IDENTITY_ALREADY_LINKED/.test(recorded.error.message ?? "");
      return json({ error: linked ? "IDENTITY_ALREADY_LINKED" : "IDENTITY_RECORD_FAILED" }, linked ? 409 : 500);
    }
  }

  // 5. Claim the email-confirmation attempt atomically. A normal duplicate registration request
  //    is idempotent and never sends a second email; an explicit resend is rate-limited server-side.
  const authUser = await admin.auth.admin.getUserById(userId);
  if (authUser.error) return json({ error: "REGISTRATION_RETRY_UNAVAILABLE" }, 503);
  let alreadyConfirmed = Boolean(authUser.data.user?.email_confirmed_at);
  let confirmationState = "ALREADY_CONFIRMED";
  let resendAfterSeconds: number | null = null;

  if (!alreadyConfirmed) {
    const claim = await admin.rpc("claim_registration_email_confirmation", {
      p_profile_id: userId,
      p_explicit_resend: resendConfirmation,
      p_cooldown_seconds: 60,
      p_max_attempts: 5,
    });
    if (claim.error || !claim.data || typeof claim.data !== "object") {
      return json({ error: "REGISTRATION_EMAIL_STATE_UNAVAILABLE" }, 503);
    }

    const decision = claim.data as Record<string, unknown>;
    const reason = typeof decision.reason === "string" ? decision.reason : "";
    resendAfterSeconds = typeof decision.retry_after_seconds === "number"
      ? decision.retry_after_seconds
      : null;

    if (decision.allowed !== true) {
      if (reason === "ALREADY_CONFIRMED") {
        alreadyConfirmed = true;
      } else if (reason === "ALREADY_REQUESTED") {
        confirmationState = "ALREADY_REQUESTED";
      } else if (reason === "COOLDOWN") {
        return json({
          error: "EMAIL_RESEND_COOLDOWN",
          retry_after_seconds: resendAfterSeconds,
          email_delivery: "UNCONFIRMED",
        }, 429);
      } else if (reason === "MAX_ATTEMPTS") {
        return json({ error: "EMAIL_RESEND_MAX_ATTEMPTS" }, 429);
      } else {
        return json({ error: "REGISTRATION_EMAIL_STATE_UNAVAILABLE" }, 503);
      }
    } else {
      const anon = createClient(url, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      });
      const resend = await anon.auth.resend({ type: "signup", email });
      if (resend.error) {
        // The attempt is consumed and the cooldown still applies, even if Auth rejects the send.
        // This prevents callers from hammering GoTrue; the user can explicitly retry after cooldown.
        return json({
          error: "EMAIL_CONFIRMATION_REQUEST_FAILED",
          status: "PENDING_EMAIL_VERIFICATION",
          email_confirmation: "NOT_CONFIRMED",
          email_delivery: "UNCONFIRMED",
          retry_after_seconds: 60,
        }, 503);
      }
      confirmationState = reason === "FIRST_REQUEST" ? "REQUESTED" : "RESENT";
    }
  }

  return json({
    status: "PENDING_EMAIL_VERIFICATION",
    identities: identities.map((identity) => identity.identity_type),
    verification_source: SYNTHETIC_VERIFICATION_SOURCE,
    email_confirmation: confirmationState,
    email_delivery: alreadyConfirmed ? "NOT_REQUESTED" : "UNCONFIRMED",
    ...(resendAfterSeconds !== null ? { resend_after_seconds: resendAfterSeconds } : {}),
    next: alreadyConfirmed
      ? "POST /functions/v1/finalize-registration with the current access token."
      : "Check the confirmation email. To request another message, retry with resend_confirmation=true after the resend cooldown.",
  }, 202);
});
