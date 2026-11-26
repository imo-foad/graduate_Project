import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ACTIVE_OPPORTUNITY_TYPES, CANCELLED_OPPORTUNITY_TYPES,
  filterAvailableRecommendations, filterOpenRecommendations,
  isActiveOpportunityType, isCancelledOpportunityType, isOpportunityOpen, registrationAvailability,
} from "../supabase/functions/_shared/opportunity-state.ts";

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
test("registration availability: upcoming, open, waitlist and full states", () => {
  const base = { status: "ACTIVE", deadline: iso(86_400_000) };
  assert.equal(registrationAvailability({ ...base, registration_opens_at: iso(1000) }, NOW), "UPCOMING");
  assert.equal(registrationAvailability({ ...base, registration_opens_at: iso(0) }, NOW), "OPEN");
  assert.equal(registrationAvailability({ ...base, capacity: 5, registered_count: 4 }, NOW), "OPEN");
  assert.equal(registrationAvailability({ ...base, capacity: 5, registered_count: 5 }, NOW), "FULL");
  assert.equal(registrationAvailability({ ...base, capacity: 5, registered_count: 5, waitlist_enabled: true }, NOW), "WAITLIST_ONLY");
  assert.equal(registrationAvailability({ ...base, capacity: 5, registered_count: 9, waitlist_enabled: true }, NOW), "WAITLIST_ONLY");
  assert.equal(registrationAvailability({ ...base, capacity: 5, registered_count: 6 }, NOW), "FULL");
  assert.equal(registrationAvailability({ ...base, capacity: null }, NOW), null);
  assert.equal(registrationAvailability({ ...base, status: "CLOSED" }, NOW), "CLOSED");
});
test("registration availability is null when no registration data is present", () => {
  assert.equal(registrationAvailability({ status: "ACTIVE" }, NOW), null);
  assert.equal(registrationAvailability(null, NOW), null);
});
test("active types: exactly the six SQL allow-list values, case-sensitive", () => {
  assert.deepEqual([...ACTIVE_OPPORTUNITY_TYPES], ["JOB", "INTERNSHIP", "TRAINING", "EVENT", "CONFERENCE", "VOLUNTEER"]);
  for (const t of ACTIVE_OPPORTUNITY_TYPES) {
    assert.equal(isActiveOpportunityType(t), true, t);
    assert.equal(isCancelledOpportunityType(t), false, t);
  }
});
test("cancelled product lines are rejected by the active allow-list", () => {
  assert.deepEqual([...CANCELLED_OPPORTUNITY_TYPES], ["SCHOLARSHIP", "COMPETITION"]);
  for (const t of ["SCHOLARSHIP", "COMPETITION"]) {
    assert.equal(isActiveOpportunityType(t), false, t);
    assert.equal(isCancelledOpportunityType(t), true, t);
  }
});
test("type matching mirrors SQL exactly: no case folding, no trimming, no unknown values", () => {
  // SQL uses `type in ('JOB', ...)`, so each of these is rejected there and must be rejected here.
  for (const t of ["job", "Job", "JOB ", " JOB", "JOBS", "SOMETHING_NEW", "", "   ", "JOB\n", "التدريب"]) {
    assert.equal(isActiveOpportunityType(t), false, JSON.stringify(t));
    assert.equal(isCancelledOpportunityType(t), false, JSON.stringify(t));
  }
});
test("null, undefined and non-string runtime values are not active", () => {
  for (const t of [null, undefined]) {
    assert.equal(isActiveOpportunityType(t), false, String(t));
    assert.equal(isCancelledOpportunityType(t), false, String(t));
  }
  // Outside the TypeScript contract, but a JS caller can still pass these: never active.
  for (const t of [0, 42, true, {}, [], ["JOB"]]) {
    assert.equal(isActiveOpportunityType(t as unknown as string), false, JSON.stringify(t));
    assert.equal(isCancelledOpportunityType(t as unknown as string), false, JSON.stringify(t));
  }
});
test("cached recommendations: full-without-waitlist and closed rows are dropped, waitlist/upcoming kept", () => {
  const cached = [
    { id: "open", opportunity: { type: "JOB", status: "ACTIVE", capacity: 10, registered_count: 1 } },
    { id: "waitlist", opportunity: { type: "EVENT", status: "ACTIVE", capacity: 10, registered_count: 10, waitlist_enabled: true } },
    { id: "upcoming", opportunity: { type: "EVENT", status: "ACTIVE", registration_opens_at: iso(1000) } },
    { id: "full", opportunity: { type: "EVENT", status: "ACTIVE", capacity: 10, registered_count: 10 } },
    { id: "closed", opportunity: { type: "JOB", status: "CLOSED" } },
  ];
  assert.deepEqual(filterAvailableRecommendations(cached, NOW).map((r) => r.id), ["open", "waitlist", "upcoming"]);
});
test("cached recommendations: cancelled product lines are dropped even when still ACTIVE", () => {
  const cached = [
    { id: "job", opportunity: { type: "JOB", status: "ACTIVE" } },
    { id: "scholarship", opportunity: { type: "SCHOLARSHIP", status: "ACTIVE" } },
    { id: "competition", opportunity: { type: "COMPETITION", status: "ACTIVE" } },
  ];
  assert.deepEqual(filterAvailableRecommendations(cached, NOW).map((r) => r.id), ["job"]);
});
test("cached recommendations: values SQL rejects are dropped too (unknown, case, padding, missing)", () => {
  const cached = [
    { id: "job", opportunity: { type: "JOB", status: "ACTIVE" } },
    { id: "unknown", opportunity: { type: "SOMETHING_NEW", status: "ACTIVE" } },
    { id: "lowercase", opportunity: { type: "job", status: "ACTIVE" } },
    { id: "padded", opportunity: { type: "JOB ", status: "ACTIVE" } },
    { id: "empty", opportunity: { type: "", status: "ACTIVE" } },
    { id: "missing", opportunity: { status: "ACTIVE" } },
  ];
  assert.deepEqual(filterAvailableRecommendations(cached, NOW).map((r) => r.id), ["job"]);
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
