import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CV_CLEANUP_STORAGE_FAILURE,
  CV_CLEANUP_UNSAFE_PATH,
  drainCvCleanup,
  isSafeCvCleanupPath,
  type CvCleanupDeps,
  type CvCleanupItem,
} from "../supabase/functions/_shared/cv-cleanup-runner.ts";

const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

function harness(queue: CvCleanupItem[], opts: { removeError?: (path: string) => string | null;
  completeFails?: (id: string) => boolean; failFails?: (id: string) => boolean;
  claimError?: string; batchSize?: number } = {}) {
  const removed: string[] = [];
  const completed: string[] = [];
  const failed: Array<{ id: string; code: string }> = [];
  const logs: Array<{ event: string; meta?: Record<string, unknown> }> = [];
  const state = queue.map((item) => ({ ...item }));
  const deps: CvCleanupDeps = {
    async claim(limit) {
      if (opts.claimError) return { items: [], errorCode: opts.claimError };
      const due = state.splice(0, Math.min(limit, opts.batchSize ?? limit));
      return { items: due };
    },
    async remove(path) {
      if (opts.removeError) {
        const code = opts.removeError(path);
        if (code) return { errorCode: code };
      }
      removed.push(path);
      return { errorCode: null };
    },
    async complete(id) {
      if (opts.completeFails?.(id)) return { completed: false, errorCode: "NO_ROW" };
      completed.push(id);
      return { completed: true };
    },
    async fail(id, code) {
      if (opts.failFails?.(id)) return { completed: false, errorCode: "NO_ROW" };
      failed.push({ id, code });
      return { completed: true };
    },
    log(event, meta) { logs.push({ event, meta }); },
  };
  return { deps, removed, completed, failed, logs };
}

test("uploads a delete for every claimed row and marks it DONE", async () => {
  const h = harness([
    { id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER },
    { id: "b", storage_path: OWNER + "/nested/b.docx", graduate_id: OWNER },
  ]);
  const result = await drainCvCleanup(h.deps);
  assert.deepEqual(result, { ok: true, processed: 2, done: 2, failed: 0 });
  assert.deepEqual(h.completed, ["a", "b"]);
  assert.deepEqual(h.failed, []);
});

test("a Storage deletion failure is recorded, is never marked DONE, and is retried on the next run", async () => {
  let failNext = true;
  const h = harness([{ id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER }], {
    removeError: () => (failNext ? "503 slow down" : null),
  });
  const first = await drainCvCleanup(h.deps);
  assert.deepEqual(first, { ok: true, processed: 1, done: 0, failed: 1 });
  assert.deepEqual(h.completed, [], "a failed delete must never be marked DONE");
  assert.deepEqual(h.failed, [{ id: "a", code: CV_CLEANUP_STORAGE_FAILURE }]);

  // Postgres owns the schedule; the next invocation that can claim the row performs the real delete.
  failNext = false;
  const retry = await drainCvCleanup(harness([{ id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER }]).deps);
  assert.deepEqual(retry, { ok: true, processed: 1, done: 1, failed: 0 });
});

test("provider error text is not persisted or logged, and storage paths never reach the log sink", async () => {
  const h = harness([{ id: "a", storage_path: OWNER + "/private-name.pdf", graduate_id: OWNER }], {
    removeError: () => "AccessDenied: cv-documents/" + OWNER + "/private-name.pdf",
  });
  await drainCvCleanup(h.deps);
  assert.deepEqual(h.failed, [{ id: "a", code: CV_CLEANUP_STORAGE_FAILURE }]);
  const serialized = JSON.stringify(h.logs);
  assert.equal(serialized.includes("private-name.pdf"), false);
  assert.equal(serialized.includes("AccessDenied"), false);
});

test("unsafe storage paths are rejected before the Storage call and stay retryable", async () => {
  const unsafe = [
    "../../etc/passwd",
    "/" + OWNER + "/absolute.pdf",
    OWNER + "/../" + OTHER + "/steal.pdf",
    OWNER + "//double.pdf",
    OWNER + "/back\\slash.pdf",
    OTHER + "/someone-else.pdf",
    "not-a-uuid/file.pdf",
  ];
  const h = harness(unsafe.map((path, index) => ({
    id: "u" + index, storage_path: path, graduate_id: OWNER,
  })));
  const result = await drainCvCleanup(h.deps);
  assert.equal(result.processed, unsafe.length);
  assert.equal(result.done, 0);
  assert.equal(result.failed, unsafe.length);
  assert.deepEqual(h.removed, [], "no unsafe path may reach the Storage API");
  assert.ok(h.failed.every((entry) => entry.code === CV_CLEANUP_UNSAFE_PATH));
});

test("path validation accepts only UUID-owner keys inside the owning graduate prefix", () => {
  assert.equal(isSafeCvCleanupPath(OWNER + "/cv.pdf", OWNER), true);
  assert.equal(isSafeCvCleanupPath(OWNER + "/a/b/c.docx", OWNER), true);
  assert.equal(isSafeCvCleanupPath(OWNER + "/cv.pdf", OTHER), false);
  assert.equal(isSafeCvCleanupPath(OWNER + "/cv.pdf", null), true);
  assert.equal(isSafeCvCleanupPath("", null), false);
  assert.equal(isSafeCvCleanupPath(OWNER + "/x".repeat(1024), null), false);
});

test("a completion failure counts as failed, keeps the ledger recoverable and stops the batch", async () => {
  const h = harness(
    [{ id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER },
      { id: "b", storage_path: OWNER + "/b.pdf", graduate_id: OWNER }],
    { completeFails: (id) => id === "a" },
  );
  const result = await drainCvCleanup(h.deps);
  assert.deepEqual(result, { ok: true, processed: 2, done: 1, failed: 1 });
  assert.deepEqual(h.completed, ["b"], "the batch must still record the other item");
  assert.equal(h.logs.some((entry) => entry.event === "cv_cleanup_completion_not_recorded"), true);
});

test("failure recording that cannot find the row is logged, not silently swallowed", async () => {
  const h = harness([{ id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER }], {
    removeError: () => "boom",
    failFails: () => true,
  });
  const result = await drainCvCleanup(h.deps);
  assert.equal(result.failed, 1);
  assert.equal(h.logs.some((entry) => entry.event === "cv_cleanup_failure_not_recorded"), true);
});

test("batches stop after a failure and never reclaim the same invocation", async () => {
  const queue: CvCleanupItem[] = Array.from({ length: 120 }, (_, index) => ({
    id: "i" + index, storage_path: OWNER + "/f" + index + ".pdf", graduate_id: OWNER,
  }));
  const h = harness(queue, { removeError: (path) => (path.endsWith("/f0.pdf") ? "fail" : null) });
  const result = await drainCvCleanup(h.deps, { batchSize: 50 });
  assert.equal(result.processed, 50, "a failing batch must stop the loop, not continue into later batches");
  assert.equal(result.done, 49);
  assert.equal(result.failed, 1);
});

test("a successful run is bounded to five full batches per invocation", async () => {
  const queue: CvCleanupItem[] = Array.from({ length: 400 }, (_, index) => ({
    id: "i" + index, storage_path: OWNER + "/f" + index + ".pdf", graduate_id: OWNER,
  }));
  const h = harness(queue);
  const result = await drainCvCleanup(h.deps, { batchSize: 10, maxBatches: 3 });
  assert.equal(result.processed, 30);
  assert.equal(result.done, 30);
});

test("a claim RPC error returns a 503-shaped failure and does not process anything", async () => {
  const h = harness([], { claimError: "57014" });
  const result = await drainCvCleanup(h.deps);
  assert.deepEqual(result, { ok: false, error: "CLEANUP_CLAIM_FAILED", processed: 0, done: 0, failed: 0 });
  assert.equal(h.logs[0]?.event, "cv_cleanup_claim_failed");
});

test("duplicate rows in one claim are not deleted twice", async () => {
  const h = harness([
    { id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER },
    { id: "a", storage_path: OWNER + "/a.pdf", graduate_id: OWNER },
  ]);
  const result = await drainCvCleanup(h.deps);
  assert.equal(result.processed, 1);
  assert.deepEqual(h.removed, [OWNER + "/a.pdf"]);
  assert.equal(h.logs.some((entry) => entry.event === "cv_cleanup_duplicate_claim"), true);
});
