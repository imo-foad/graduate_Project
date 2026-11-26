import { test } from "node:test";
import assert from "node:assert/strict";
import { filterAvailableRecommendations, filterOpenRecommendations, isOpportunityOpen, registrationAvailability } from "../supabase/functions/_shared/opportunity-state.ts";

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
test("cached recommendations: full-without-waitlist and closed rows are dropped, waitlist/upcoming kept", () => {
  const cached = [
    { id: "open", opportunity: { status: "ACTIVE", capacity: 10, registered_count: 1 } },
    { id: "waitlist", opportunity: { status: "ACTIVE", capacity: 10, registered_count: 10, waitlist_enabled: true } },
    { id: "upcoming", opportunity: { status: "ACTIVE", registration_opens_at: iso(1000) } },
    { id: "full", opportunity: { status: "ACTIVE", capacity: 10, registered_count: 10 } },
    { id: "closed", opportunity: { status: "CLOSED" } },
  ];
  assert.deepEqual(filterAvailableRecommendations(cached, NOW).map((r) => r.id), ["open", "waitlist", "upcoming"]);
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
