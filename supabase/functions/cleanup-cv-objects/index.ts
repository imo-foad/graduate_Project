// Service-role worker for private CV Storage cleanup (issue #18).
//
// Ordinary metadata deletion is handled by the owner-scoped RPC delete_cv_document, which writes a
// durable row to private.cv_cleanup_queue. This function drains that queue through the real Storage API:
//   claim (transactional, SKIP LOCKED) -> path validation -> storage.remove (idempotent) -> complete/fail.
// It never touches storage.objects with SQL, never logs storage paths, and is safe to run repeatedly.
// Authorization: operator/cron only. The caller must present the service-role JWT, and the queue RPCs
// are executable by service_role only.
import { drainCvCleanup, type CvCleanupItem } from "../_shared/cv-cleanup-runner.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";
const STORAGE_TIMEOUT_MS = 20_000;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization") ?? "";
  if (!url || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  if (!authorization.startsWith("Bearer ") || authorization.slice("Bearer ".length) !== serviceKey) {
    return json({ error: "SERVICE_ROLE_REQUIRED" }, 403);
  }

  // Deno's Supabase client is already used elsewhere in this project; keep the dependency identical.
  const { createClient } = await import("npm:@supabase/supabase-js@2");
  // A hung Storage or PostgREST request must not hold a queue lease indefinitely.
  const fetchWithTimeout: typeof fetch = (input, init) =>
    fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(STORAGE_TIMEOUT_MS) });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: fetchWithTimeout },
  });

  const result = await drainCvCleanup({
    async claim(limit) {
      const { data, error } = await admin.rpc("claim_cv_cleanup", { p_limit: limit });
      if (error) return { items: [], errorCode: error.code ?? "CLAIM_ERROR" };
      return { items: (Array.isArray(data) ? data : []) as CvCleanupItem[] };
    },
    async remove(path) {
      const { error } = await admin.storage.from("cv-documents").remove([path]);
      // Supabase Storage treats an already-absent object as a successful delete, which keeps the
      // operation idempotent. Any returned error is recorded by the caller as a stable code only.
      return { errorCode: error ? "STORAGE_DELETE_ERROR" : null };
    },
    async complete(id) {
      const { data, error } = await admin.rpc("complete_cv_cleanup", { p_id: id });
      return { completed: !error && data === true, ...(error ? { errorCode: error.code ?? "COMPLETE_ERROR" } : {}) };
    },
    async fail(id, errorCode) {
      const { data, error } = await admin.rpc("fail_cv_cleanup", { p_id: id, p_error: errorCode });
      return { completed: !error && data === true, ...(error ? { errorCode: error.code ?? "FAIL_ERROR" } : {}) };
    },
    log(event, meta) {
      // Never include a storage path, file name, or CV content in operator logs.
      console.error(event, meta ?? {});
    },
  });

  if (!result.ok) {
    return json({ error: "CLEANUP_CLAIM_FAILED", processed: result.processed, done: result.done, failed: result.failed }, 503);
  }
  return json({ processed: result.processed, done: result.done, failed: result.failed }, 200);
});
