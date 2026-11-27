// Orchestration for the service-role CV Storage cleanup worker (issue #18).
//
// The queue and retry policy live in Postgres (migrations 0027, 0030, 0039); the actual object bytes are
// removed only through the Storage API. This module owns the part in between and takes every external
// effect as an injected dependency, so a deterministic local test can exercise a Storage deletion failure
// without a production fault-injection parameter, a test-only endpoint, or privileged credentials.

export interface CvCleanupItem {
  id: string;
  storage_path: string;
  graduate_id?: string | null;
  attempts?: number;
}

export interface CvCleanupBatch {
  items: CvCleanupItem[];
  errorCode?: string;
}

export interface CvCleanupDeps {
  /** Transactionally claim up to `limit` due rows. */
  claim(limit: number): Promise<CvCleanupBatch>;
  /** Remove one private object. Resolve `errorCode: null` only when the Storage API accepted the delete. */
  remove(path: string): Promise<{ errorCode: string | null }>;
  /** Mark a claimed row DONE. `completed: false` means the row was no longer claimed (lease recovery). */
  complete(id: string): Promise<{ completed: boolean; errorCode?: string }>;
  /** Record a failure and let Postgres schedule the next attempt. */
  fail(id: string, errorCode: string): Promise<{ completed: boolean; errorCode?: string }>;
  /** Structured, path-free diagnostic sink. */
  log(event: string, meta?: Record<string, string | number | boolean | null>): void;
}

export interface CvCleanupResult {
  ok: boolean;
  error?: "CLEANUP_CLAIM_FAILED";
  processed: number;
  done: number;
  failed: number;
}

export const CV_CLEANUP_BATCH_SIZE = 50;
export const CV_CLEANUP_MAX_BATCHES = 5;
export const CV_CLEANUP_STORAGE_FAILURE = "STORAGE_DELETE_FAILED";
export const CV_CLEANUP_UNSAFE_PATH = "UNSAFE_STORAGE_PATH";

const UUID_OWNER_PREFIX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\//i;

/**
 * A cleanup path must be a private object key under a UUID owner folder: no traversal, no absolute or
 * duplicate separators, no backslashes, bounded length. When the queue row knows its graduate, the key
 * must be inside that graduate's own prefix. Rejecting the path before the Storage call means a
 * malformed or tampered queue row can never delete another user's object or escape the CV bucket.
 */
export function isSafeCvCleanupPath(path: unknown, graduateId?: string | null): boolean {
  if (typeof path !== "string" || path.length < 1 || path.length > 1024) return false;
  if (path.startsWith("/") || path.endsWith("/")) return false;
  if (path.includes("\\") || path.includes("\u0000") || path.includes("//")) return false;
  if (path.split("/").some((segment) => segment === "" || segment === "." || segment === "..")) return false;
  if (!UUID_OWNER_PREFIX.test(path)) return false;
  if (graduateId && !path.startsWith(graduateId + "/")) return false;
  return true;
}

/**
 * Drain due cleanup rows. At most five batches of fifty rows are touched per invocation, so a single
 * request cannot run unbounded. A batch that recorded any failure stops the loop: failed rows are
 * scheduled by Postgres for a later attempt and must not be reclaimed in the same invocation.
 */
export async function drainCvCleanup(
  deps: CvCleanupDeps,
  options: { batchSize?: number; maxBatches?: number } = {},
): Promise<CvCleanupResult> {
  const batchSize = Math.max(1, Math.min(options.batchSize ?? CV_CLEANUP_BATCH_SIZE, 100));
  const maxBatches = Math.max(1, Math.min(options.maxBatches ?? CV_CLEANUP_MAX_BATCHES, 20));
  let processed = 0;
  let done = 0;
  let failed = 0;

  for (let batch = 0; batch < maxBatches; batch++) {
    const claimed = await deps.claim(batchSize);
    if (claimed.errorCode !== undefined) {
      deps.log("cv_cleanup_claim_failed", { code: claimed.errorCode, processed, done, failed });
      return { ok: false, error: "CLEANUP_CLAIM_FAILED", processed, done, failed };
    }

    const items = claimed.items.filter((item) => item && typeof item.id === "string");
    if (items.length === 0) break;

    let failedThisBatch = false;
    const seen = new Set<string>();
    for (const item of items) {
      // A claim function must not return the same row twice; ignore a duplicate rather than delete twice.
      if (seen.has(item.id)) {
        deps.log("cv_cleanup_duplicate_claim", { id: item.id });
        continue;
      }
      seen.add(item.id);
      processed++;

      if (!isSafeCvCleanupPath(item.storage_path, item.graduate_id)) {
        failed++;
        failedThisBatch = true;
        const marked = await deps.fail(item.id, CV_CLEANUP_UNSAFE_PATH);
        if (!marked.completed) {
          deps.log("cv_cleanup_failure_not_recorded", { code: marked.errorCode ?? "NO_ROW" });
        }
        continue;
      }

      const removal = await deps.remove(item.storage_path);
      if (removal.errorCode) {
        failed++;
        failedThisBatch = true;
        // Provider error text can echo the private object key, so only a stable code is persisted/logged.
        const marked = await deps.fail(item.id, CV_CLEANUP_STORAGE_FAILURE);
        if (!marked.completed) {
          deps.log("cv_cleanup_failure_not_recorded", { code: marked.errorCode ?? "NO_ROW" });
        }
        continue;
      }

      const completion = await deps.complete(item.id);
      if (!completion.completed) {
        // The object is gone but the ledger could not be marked DONE. The row keeps its lease and is
        // recovered by the next claim after the lease expires; re-running remove is idempotent.
        failed++;
        failedThisBatch = true;
        deps.log("cv_cleanup_completion_not_recorded", { code: completion.errorCode ?? "NO_ROW" });
        continue;
      }
      done++;
    }

    if (items.length < batchSize || failedThisBatch) break;
  }

  return { ok: true, processed, done, failed };
}
