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
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
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

  const { data: isAdmin, error: adminCheckError } = await userClient.rpc("assert_platform_admin");
  if (adminCheckError || isAdmin !== true) return json({ error: "ADMIN_REQUIRED" }, 403);

  const body = await req.json().catch(() => null);
  if (
    !body || typeof body !== "object" || Array.isArray(body) ||
    Object.keys(body).some((key) => !["email", "full_name", "verification_note"].includes(key)) ||
    typeof body.email !== "string" ||
    typeof body.full_name !== "string" ||
    typeof body.verification_note !== "string"
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const email = body.email.trim().toLowerCase();
  const fullName = body.full_name.trim();
  const verificationNote = body.verification_note.trim();
  if (
    email.length < 6 || email.length > 254 ||
    fullName.length < 2 || fullName.length > 200 ||
    verificationNote.length < 10 || verificationNote.length > 2000
  ) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const { data: invitationRows, error: createError } = await userClient.rpc(
    "create_graduate_invitation",
    {
      p_email: email,
      p_full_name: fullName,
      p_verification_note: verificationNote,
    },
  );
  if (createError) {
    const code = createError.message ?? "";
    if (code.includes("EMAIL_ALREADY_REGISTERED")) return json({ error: "EMAIL_ALREADY_REGISTERED" }, 409);
    if (code.includes("INVITATION_ALREADY_ACTIVE")) return json({ error: "INVITATION_ALREADY_ACTIVE" }, 409);
    if (code.includes("ADMIN_REQUIRED")) return json({ error: "ADMIN_REQUIRED" }, 403);
    if (code.includes("INVALID_INPUT")) return json({ error: "INVALID_REQUEST" }, 400);
    console.error("create_graduate_invitation failed", { code: createError.code });
    return json({ error: "INVITATION_CREATE_FAILED" }, 503);
  }

  const invitation = Array.isArray(invitationRows) ? invitationRows[0] : invitationRows;
  const invitationId = invitation?.invitation_id;
  if (typeof invitationId !== "string") {
    console.error("create_graduate_invitation returned an invalid result");
    return json({ error: "INVITATION_CREATE_FAILED" }, 503);
  }

  const adminClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: inviteData, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
    email,
    { data: { full_name: fullName } },
  );

  if (inviteError || !inviteData.user?.id) {
    const failureCode = inviteError ? "AUTH_INVITE_REJECTED" : "AUTH_INVITE_UNAVAILABLE";
    const { error: finalizeError } = await adminClient.rpc("finalize_graduate_invitation", {
      p_invitation_id: invitationId,
      p_auth_user_id: null,
      p_success: false,
      p_failure_code: failureCode,
    });
    if (finalizeError) console.error("invitation failure finalization failed", { code: finalizeError.code });
    if (inviteError?.status === 422 || inviteError?.status === 409) {
      return json({ error: "EMAIL_ALREADY_REGISTERED" }, 409);
    }
    return json({ error: "INVITATION_DELIVERY_FAILED" }, 502);
  }

  const { data: finalStatus, error: finalizeError } = await adminClient.rpc(
    "finalize_graduate_invitation",
    {
      p_invitation_id: invitationId,
      p_auth_user_id: inviteData.user.id,
      p_success: true,
      p_failure_code: null,
    },
  );
  if (finalizeError || !["PENDING", "ACCEPTED"].includes(finalStatus)) {
    // The invitation may already have been sent. Do not claim success or retry by creating
    // another Auth user; leave the durable INVITING row for an operator to reconcile.
    console.error("invitation sent but database finalization failed", {
      invitationId,
      code: finalizeError?.code,
    });
    return json({ error: "INVITATION_FINALIZATION_PENDING", invitation_id: invitationId }, 503);
  }

  return json({ invitation_id: invitationId, status: finalStatus }, 202);
});
