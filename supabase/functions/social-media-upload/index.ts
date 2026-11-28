// Validated Social Feed image upload.
//
// The Android client sends multipart/form-data with `file`, `actor_id` and optional `alt_text`. The
// function authenticates the caller, sniffs the real image container (JPEG/PNG/WebP), enforces size and
// pixel limits, writes the object under `<auth.uid()>/<uuid>.<ext>` in the private `social-media`
// bucket, and registers the pending metadata through the caller-scoped RPC (so auth.uid() is the real
// user, never a value supplied by the client).
//
// Client-supplied MIME type, storage path and uploader id are ignored. A rejected registration removes
// the just-uploaded object so a failed upload cannot leave an unreferenced file behind.
import {
  ALLOWED_IMAGE_MIME,
  MAX_IMAGE_BYTES,
  SOCIAL_MEDIA_BUCKET,
  validateSocialImage,
} from "../_shared/social-media.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";

// PT422/PT403/PT404/PT409/PT429 are used by the database contract; anything else is a server fault.
function statusForCode(code: string): number {
  if (code === "PT401" || code === "UNAUTHENTICATED") return 401;
  if (code === "PT403") return 403;
  if (code === "PT404") return 404;
  if (code === "PT409") return 409;
  if (code === "PT422") return 422;
  if (code === "PT429") return 429;
  return 400;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = env("SUPABASE_URL");
  const anonKey = env("SUPABASE_ANON_KEY");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "UNAUTHENTICATED" }, 401);

  const { createClient } = await import("npm:@supabase/supabase-js@2");
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const caller = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: authorization } },
  });

  // The gateway verifies the JWT; this call additionally proves the session still belongs to a user.
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData?.user) return json({ error: "UNAUTHENTICATED" }, 401);
  const callerId = userData.user.id;

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return json({ error: "SOCIAL_MEDIA_INVALID" }, 422);
  }
  const file = form.get("file");
  const actorId = String(form.get("actor_id") ?? "");
  const altText = form.get("alt_text");
  if (!(file instanceof File) || !actorId) return json({ error: "SOCIAL_MEDIA_INVALID" }, 422);
  if (file.size > MAX_IMAGE_BYTES) return json({ error: "SOCIAL_MEDIA_TOO_LARGE" }, 422);

  const bytes = new Uint8Array(await file.arrayBuffer());
  const verdict = validateSocialImage(bytes, file.type);
  if (!verdict.ok) return json({ error: verdict.error }, 422);

  const path = `${callerId}/${crypto.randomUUID()}.${verdict.extension}`;
  const upload = await admin.storage
    .from(SOCIAL_MEDIA_BUCKET)
    .upload(path, bytes, { contentType: verdict.mime, upsert: false });
  if (upload.error) return json({ error: "SOCIAL_MEDIA_UPLOAD_FAILED" }, 503);

  const { data, error } = await caller.rpc("register_social_media", {
    p_actor_id: actorId,
    p_storage_path: path,
    p_mime_type: verdict.mime,
    p_size_bytes: verdict.size,
    p_width: verdict.width,
    p_height: verdict.height,
    p_alt_text: typeof altText === "string" && altText.trim() ? altText.trim() : null,
  });
  if (error) {
    // Never leave an orphan object when the metadata step rejects the upload.
    await admin.storage.from(SOCIAL_MEDIA_BUCKET).remove([path]).catch(() => {});
    const code = (error.message ?? "").trim();
    return json(
      { error: code || "SOCIAL_MEDIA_REGISTER_FAILED", allowed_mime_types: ALLOWED_IMAGE_MIME },
      statusForCode(error.code?.startsWith("PT") ? error.code : code),
    );
  }

  return json(
    {
      media_id: data?.media_id ?? null,
      status: "PENDING",
      bucket_id: SOCIAL_MEDIA_BUCKET,
      storage_path: path,
      mime_type: verdict.mime,
      size_bytes: verdict.size,
      width: verdict.width,
      height: verdict.height,
      alt_text: data?.alt_text ?? null,
    },
    201,
  );
});
