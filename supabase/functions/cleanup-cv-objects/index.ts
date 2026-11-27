// Service-role worker for private CV Storage cleanup (issue #18).
//
// Ordinary metadata deletion is handled by the owner-scoped RPC delete_cv_document, which writes a
// durable row to private.cv_cleanup_queue. This function drains that queue through the real Storage API:
//   claim (transactional, SKIP LOCKED) -> storage.remove (idempotent) -> complete/fail.
// It never touches storage.objects with SQL, never logs storage paths, and is safe to run repeatedly.
// Authorization: operator/cron only. The caller must present the service-role JWT, and the queue RPCs
// are executable by service_role only.
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const env = (key: string) => Deno.env.get(key) ?? "";

interface CleanupItem { id: string; storage_path: string; attempts: number }

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
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  let processed = 0, done = 0, failed = 0;
  for (let batch = 0; batch < 5; batch++) {
    const { data: claimed, error: claimError } = await admin.rpc("claim_cv_cleanup", { p_limit: 50 });
    if (claimError) {
      console.error("CV cleanup claim failed", { code: claimError.code });
      return json({ error: "CLEANUP_CLAIM_FAILED", processed, done, failed }, 503);
    }
    const items = (Array.isArray(claimed) ? claimed : []) as CleanupItem[];
    if (items.length === 0) break;
    let failedThisBatch = false;
    for (const item of items) {
      processed++;
      const { error: storageError } = await admin.storage.from("cv-documents").remove([item.storage_path]);
      if (storageError) {
        failed++;
        failedThisBatch = true;
        const { error: markError } = await admin.rpc("fail_cv_cleanup", {
          p_id: item.id,
          // Do not persist provider error text: it can echo a private object key/path.
          // The durable queue stores a stable code; operators can correlate provider logs by request time.
          p_error: "STORAGE_DELETE_FAILED",
        });
        if (markError) console.error("CV cleanup failure could not be recorded", { code: markError.code });
        continue;
      }
      const { data: completed, error: completeError } = await admin.rpc("complete_cv_cleanup", { p_id: item.id });
      if (completeError || completed !== true) {
        failed++;
        failedThisBatch = true;
        console.error("CV cleanup completion could not be recorded", { code: completeError?.code ?? "NO_ROW" });
        continue;
      }
      done++;
    }
    // Never reclaim a just-failed item again in the same invocation. It becomes eligible on the
    // next worker run, and an unrecorded completion is recovered after its lease expires.
    if (items.length < 50 || failedThisBatch) break;
  }
  return json({ processed, done, failed }, 200);
});
