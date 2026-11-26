// Unit tests with injected fakes (NOT a substitute for running the Edge Function locally under Deno).
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_ATTEMPTS, runRecommend } from "../supabase/functions/_shared/recommend-flow.ts";
import type { FlowDeps } from "../supabase/functions/_shared/recommend-flow.ts";

const NOW = Date.now();
const cand = (v: number) => ({ profile_version: v, profile: { career_interests: [], experience_years: 0 }, skills: [],
  opportunities: [{ id: "o1", type: "JOB", title: "t", skills: [], eligibility_failures: [] }] });

function deps(over: Partial<FlowDeps> & { versions?: number[]; saveErrors?: (string | null)[] } = {}) {
  const calls = { candidates: 0, save: [] as number[], read: 0 };
  const versions = over.versions ?? [7, 7, 7, 7];
  const errs = over.saveErrors ?? [null];
  const d: FlowDeps = {
    cacheState: over.cacheState ?? (async () => ({ dirty: true, count: 0 })),
    candidates: over.candidates ?? (async () => ({ data: cand(versions[Math.min(calls.candidates++, versions.length - 1)]) })),
    save: over.save ?? (async (_items, v) => {
      calls.save.push(v);
      const e = errs[Math.min(calls.save.length - 1, errs.length - 1)];
      return { error: e ? { message: e } : null };
    }),
    readCached: over.readCached ?? (async () => { calls.read++; return { data: [
      { opportunity: { type: "JOB", status: "ACTIVE", deadline: new Date(NOW + 1e6).toISOString() } },
      { opportunity: { type: "JOB", status: "ACTIVE", deadline: new Date(NOW - 1e6).toISOString() } },
      { opportunity: { type: "JOB", status: "CLOSED" } }] }; }),
  };
  return { d, calls };
}

test("fresh cache: no recomputation, no save", async () => {
  const { d, calls } = deps({ cacheState: async () => ({ dirty: false, count: 3 }) });
  const r = await runRecommend(d);
  assert.equal(r.status, 200); assert.equal(r.body.source, "cache");
  assert.equal(calls.candidates, 0); assert.equal(calls.save.length, 0);
});
test("dirty profile: computes once and passes the candidates' version unchanged to save", async () => {
  const { d, calls } = deps({ versions: [42] });
  const r = await runRecommend(d);
  assert.equal(r.body.source, "computed"); assert.deepEqual(calls.save, [42]);
});
test("STALE_SNAPSHOT triggers a recompute with the NEW version, then succeeds", async () => {
  const { d, calls } = deps({ versions: [1, 2], saveErrors: ["STALE_SNAPSHOT", null] });
  const r = await runRecommend(d);
  assert.equal(r.status, 200); assert.deepEqual(calls.save, [1, 2]);
});
test("retries are bounded: persistent staleness ends in 409 after MAX_ATTEMPTS and never reads/serves new cache", async () => {
  const { d, calls } = deps({ versions: [1, 2, 3, 4, 5, 6], saveErrors: ["STALE_SNAPSHOT"] });
  const r = await runRecommend(d, { maxAttempts: 999 });
  assert.equal(r.status, 409); assert.equal(r.body.error, "STALE_SNAPSHOT");
  assert.equal(calls.save.length, MAX_ATTEMPTS); assert.equal(calls.read, 0);
});
test("OPPORTUNITY_UNAVAILABLE is retried; INVALID_ITEMS is not", async () => {
  const a = deps({ saveErrors: ["OPPORTUNITY_UNAVAILABLE", null] });
  assert.equal((await runRecommend(a.d)).status, 200); assert.equal(a.calls.save.length, 2);
  const b = deps({ saveErrors: ["INVALID_ITEMS"] });
  const r = await runRecommend(b.d);
  assert.equal(r.status, 500); assert.equal(b.calls.save.length, 1);
});
test("candidate fetch failure aborts without saving", async () => {
  const { d, calls } = deps({ candidates: async () => ({ error: { message: "boom" } }) });
  assert.equal((await runRecommend(d)).status, 500); assert.equal(calls.save.length, 0);
});
test("force=true recomputes even when the cache is fresh", async () => {
  const { d, calls } = deps({ cacheState: async () => ({ dirty: false, count: 3 }), versions: [9] });
  await runRecommend(d, { force: true });
  assert.deepEqual(calls.save, [9]);
});
test("response drops expired/closed cached rows", async () => {
  const { d } = deps({ cacheState: async () => ({ dirty: false, count: 3 }) });
  const r = await runRecommend(d);
  assert.equal((r.body.items as unknown[]).length, 1);
});
test("cached rows are filtered by current availability and report their status", async () => {
  const { d } = deps({
    cacheState: async () => ({ dirty: false, count: 4 }),
    readCached: async () => ({ data: [
      { id: "open", opportunity: { type: "JOB", status: "ACTIVE", capacity: 10, registered_count: 1 } },
      { id: "waitlist", opportunity: { type: "EVENT", status: "ACTIVE", capacity: 10, registered_count: 10, waitlist_enabled: true } },
      { id: "full", opportunity: { type: "EVENT", status: "ACTIVE", capacity: 10, registered_count: 10 } },
      { id: "upcoming", opportunity: { type: "EVENT", status: "ACTIVE", registration_opens_at: new Date(NOW + 1e6).toISOString() } },
    ] }),
  });
  const r = await runRecommend(d);
  const items = r.body.items as { id: string; availability_status: string | null }[];
  assert.deepEqual(items.map((item) => [item.id, item.availability_status]),
    [["open", "OPEN"], ["waitlist", "WAITLIST_ONLY"], ["upcoming", "UPCOMING"]]);
});
