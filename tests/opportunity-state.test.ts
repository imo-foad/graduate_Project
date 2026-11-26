import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ACTIVE_OPPORTUNITY_TYPES, CANCELLED_OPPORTUNITY_TYPES, INACTIVE_OPPORTUNITY_TYPES, OUT_OF_SCOPE_OPPORTUNITY_TYPES,
  filterAvailableRecommendations, filterOpenRecommendations,
  isActiveOpportunityType, isCancelledOpportunityType, isOpportunityOpen, isOutOfScopeOpportunityType,
  registrationAvailability,
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

test("registration availability: upcoming, open, waitlist and full states (TRAINING)", () => {
  const base = { type: "TRAINING", status: "ACTIVE", deadline: iso(86_400_000) };
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
  assert.equal(registrationAvailability({ type: "TRAINING", status: "ACTIVE" }, NOW), null);
  assert.equal(registrationAvailability(null, NOW), null);
});

test("active types: exactly JOB, INTERNSHIP and TRAINING, case-sensitive and exact", () => {
  assert.deepEqual([...ACTIVE_OPPORTUNITY_TYPES], ["JOB", "INTERNSHIP", "TRAINING"]);
  for (const t of ACTIVE_OPPORTUNITY_TYPES) {
    assert.equal(isActiveOpportunityType(t), true, t);
    assert.equal(isCancelledOpportunityType(t), false, t);
    assert.equal(isOutOfScopeOpportunityType(t), false, t);
  }
});
test("excluded product types are never active", () => {
  assert.deepEqual([...OUT_OF_SCOPE_OPPORTUNITY_TYPES], ["EVENT", "CONFERENCE", "VOLUNTEER"]);
  for (const t of OUT_OF_SCOPE_OPPORTUNITY_TYPES) {
    assert.equal(isActiveOpportunityType(t), false, t);
    assert.equal(isOutOfScopeOpportunityType(t), true, t);
    assert.equal(isCancelledOpportunityType(t), false, t);
  }
});
test("cancelled product lines are rejected by the active allow-list", () => {
  assert.deepEqual([...CANCELLED_OPPORTUNITY_TYPES], ["SCHOLARSHIP", "COMPETITION"]);
  for (const t of CANCELLED_OPPORTUNITY_TYPES) {
    assert.equal(isActiveOpportunityType(t), false, t);
    assert.equal(isCancelledOpportunityType(t), true, t);
    assert.equal(isOutOfScopeOpportunityType(t), false, t);
  }
  assert.deepEqual([...INACTIVE_OPPORTUNITY_TYPES].sort(), ["COMPETITION", "CONFERENCE", "EVENT", "SCHOLARSHIP", "VOLUNTEER"]);
});
test("type matching mirrors SQL exactly: no case folding, no trimming, no unknown values", () => {
  // SQL uses `type in ('JOB','INTERNSHIP','TRAINING')`, so each of these is rejected there and here.
  for (const t of ["job", "Job", "JOB ", " JOB", "JOBS", "SOMETHING_NEW", "", "   ", "JOB\n", "التدريب", "INTERNSHIPS", "TRAINING\u00a0"]) {
    assert.equal(isActiveOpportunityType(t), false, JSON.stringify(t));
    assert.equal(isCancelledOpportunityType(t), false, JSON.stringify(t));
    assert.equal(isOutOfScopeOpportunityType(t), false, JSON.stringify(t));
  }
});
test("null, undefined and non-string runtime values are not active", () => {
  for (const t of [null, undefined]) {
    assert.equal(isActiveOpportunityType(t), false, String(t));
    assert.equal(isCancelledOpportunityType(t), false, String(t));
    assert.equal(isOutOfScopeOpportunityType(t), false, String(t));
  }
  // Outside the TypeScript contract, but a JS caller can still pass these: never active.
  for (const t of [0, 42, true, {}, [], ["JOB"]]) {
    assert.equal(isActiveOpportunityType(t as unknown as string), false, JSON.stringify(t));
    assert.equal(isCancelledOpportunityType(t as unknown as string), false, JSON.stringify(t));
    assert.equal(isOutOfScopeOpportunityType(t as unknown as string), false, JSON.stringify(t));
  }
});

test("cached recommendations: active types kept; full-without-waitlist and closed rows dropped", () => {
  const cached = [
    { id: "job", opportunity: { type: "JOB", status: "ACTIVE", capacity: 10, registered_count: 1 } },
    { id: "internship", opportunity: { type: "INTERNSHIP", status: "ACTIVE" } },
    { id: "training-waitlist", opportunity: { type: "TRAINING", status: "ACTIVE", capacity: 10, registered_count: 10, waitlist_enabled: true } },
    { id: "training-upcoming", opportunity: { type: "TRAINING", status: "ACTIVE", registration_opens_at: iso(1000) } },
    { id: "training-full", opportunity: { type: "TRAINING", status: "ACTIVE", capacity: 10, registered_count: 10 } },
    { id: "closed", opportunity: { type: "JOB", status: "CLOSED" } },
  ];
  assert.deepEqual(filterAvailableRecommendations(cached, NOW).map((r) => r.id),
    ["job", "internship", "training-waitlist", "training-upcoming"]);
});
test("cached recommendations: every non-active type is dropped even when still ACTIVE", () => {
  const cached = [
    { id: "job", opportunity: { type: "JOB", status: "ACTIVE" } },
    ...INACTIVE_OPPORTUNITY_TYPES.map((type) => ({ id: type, opportunity: { type, status: "ACTIVE" } })),
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
    { id: "open", opportunity: { type: "TRAINING", status: "ACTIVE", deadline: iso(1000), end_at: null } },
    { id: "expired", opportunity: { type: "TRAINING", status: "ACTIVE", deadline: iso(-1000) } },
    { id: "closed", opportunity: { type: "TRAINING", status: "CLOSED", deadline: iso(1000) } },
    { id: "ended", opportunity: { type: "TRAINING", status: "ACTIVE", end_at: iso(-1000) } },
    { id: "gone", opportunity: null },
  ];
  assert.deepEqual(filterOpenRecommendations(cached, NOW).map((r) => r.id), ["open"]);
});
