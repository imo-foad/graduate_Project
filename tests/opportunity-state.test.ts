import { test } from "node:test";
import assert from "node:assert/strict";
import { filterOpenRecommendations, isOpportunityOpen } from "../supabase/functions/_shared/opportunity-state.ts";

const NOW = new Date("2026-11-23T12:00:00Z");
const iso = (ms: number) => new Date(NOW.getTime() + ms).toISOString();

test("ACTIVE with no dates is open", () => assert.equal(isOpportunityOpen({ status: "ACTIVE" }, NOW), true));
test("non-ACTIVE statuses are closed", () => {
  for (const s of ["CLOSED", "EXPIRED", "CANCELLED", "", null, undefined]) assert.equal(isOpportunityOpen({ status: s }, NOW), false, String(s));
});
test("deadline: past is closed, exact boundary and future are open", () => {
  assert.equal(isOpportunityOpen({ status: "ACTIVE", deadline: iso(-1) }, NOW), false);
  assert.equal(isOpportunityOpen({ status: "ACTIVE", deadline: iso(0) }, NOW), true);
  assert.equal(isOpportunityOpen({ status: "ACTIVE", deadline: iso(1) }, NOW), true);
});
test("end_at: past is closed even when deadline is still in the future", () => {
  assert.equal(isOpportunityOpen({ status: "ACTIVE", deadline: iso(1000), end_at: iso(-1) }, NOW), false);
  assert.equal(isOpportunityOpen({ status: "ACTIVE", end_at: iso(0) }, NOW), true);
});
test("missing opportunity (deleted/invisible) is closed", () => {
  assert.equal(isOpportunityOpen(null, NOW), false);
  assert.equal(isOpportunityOpen(undefined, NOW), false);
});
test("cached recommendations: expired / closed / ended rows are dropped, open rows kept", () => {
  const cached = [
    { id: "open", opportunity: { status: "ACTIVE", deadline: iso(1000), end_at: null } },
    { id: "expired", opportunity: { status: "ACTIVE", deadline: iso(-1000) } },
    { id: "closed", opportunity: { status: "CLOSED", deadline: iso(1000) } },
    { id: "ended", opportunity: { status: "ACTIVE", end_at: iso(-1000) } },
    { id: "gone", opportunity: null },
  ];
  assert.deepEqual(filterOpenRecommendations(cached, NOW).map((r) => r.id), ["open"]);
});
