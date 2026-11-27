import { test } from "node:test";
import assert from "node:assert/strict";
import { rankOpportunities, scoreOpportunity, weightProfile, bandOf, skillAnalysis } from "../supabase/functions/_shared/scoring.ts";
import { demo, graduate, opps } from "./helpers.ts";

const AHMED = "graduate.android@alumni.test", SARA = "graduate.demo@alumni.test", OMAR = "graduate.cyber@alumni.test";

test("every active weight profile sums to 100 and inactive types have no profile", () => {
  for (const t of ["JOB", "INTERNSHIP", "TRAINING"]) {
    const sum = Object.values(weightProfile(t)).reduce((a, b) => a + (b ?? 0), 0);
    assert.equal(sum, 100, t);
  }
  for (const t of ["EVENT", "CONFERENCE", "VOLUNTEER", "SCHOLARSHIP", "COMPETITION", "SOMETHING_NEW", ""]) {
    assert.deepEqual(weightProfile(t), {}, t);
  }
});

test("only JOB, INTERNSHIP and TRAINING are scored or ranked (scope alignment)", () => {
  const profile = graduate(AHMED);
  const base = { title: "Listing", description: "x", status: "ACTIVE", deadline: null, end_at: null, skills: [], eligibility_failures: [] };
  for (const type of ["EVENT", "CONFERENCE", "VOLUNTEER", "SCHOLARSHIP", "COMPETITION", "SOMETHING_NEW", "", "job"]) {
    const item = scoreOpportunity(profile, { ...base, id: `outside-${type}`, type });
    assert.equal(item, null, type);
  }
  const ranked = rankOpportunities(profile, [
    ...["EVENT", "CONFERENCE", "VOLUNTEER", "SCHOLARSHIP", "COMPETITION", "SOMETHING_NEW"].map((type) =>
      ({ ...base, id: `outside-${type}`, type })),
    { ...base, id: "active-training", type: "TRAINING" },
    { ...base, id: "active-internship", type: "INTERNSHIP" },
  ]);
  assert.deepEqual(ranked.map((r) => r.opportunity_id).sort(), ["active-internship", "active-training"]);
});

test("bands follow the documented thresholds (80/65/50)", () => {
  assert.deepEqual([100, 80, 79.99, 65, 64.99, 50, 49.99, 0].map(bandOf),
    ["HIGH", "HIGH", "GOOD", "GOOD", "MEDIUM", "MEDIUM", "LOW", "LOW"]);
});

test("doc example 6.7: Android grad vs Junior Android Developer", () => {
  const item = rankOpportunities(graduate(AHMED), opps()).find((r) => r.opportunity_id === "job-android-junior")!;
  assert.deepEqual(item.matched_skill_ids.sort(), ["ANDROID", "JETPACK_COMPOSE", "KOTLIN"]);
  assert.deepEqual(item.missing_skill_ids.sort(), ["GIT", "REST_API"]);
  assert.equal(item.band, "HIGH");
  assert.match(item.explanation_ar, /ليست احتمال قبول/);
});

test("different graduates get different top jobs", () => {
  const top = (e: string) => rankOpportunities(graduate(e), opps()).filter((r) => r.opportunity_id.startsWith("job-"))[0].opportunity_id;
  assert.equal(top(AHMED), "job-android-junior");
  assert.equal(top(SARA), "job-data-analyst");
  assert.equal(top(OMAR), "job-soc-analyst");
});

test("hard eligibility failure removes the item regardless of similarity (BR-017)", () => {
  const failing = opps({ "job-soc-analyst": ["MISSING_CERTIFICATION:Security+"] });
  const ranked = rankOpportunities(graduate(OMAR), failing);
  assert.equal(ranked.some((r) => r.opportunity_id === "job-soc-analyst"), false);
  assert.equal(scoreOpportunity(graduate(OMAR), failing.find((o) => o.id === "job-soc-analyst")!), null);
});

test("expired and closed fixtures are never candidates", () => {
  const ids = opps().map((o) => o.id);
  assert.equal(ids.includes("job-expired"), false);
  assert.equal(ids.includes("job-closed"), false);
});

test("skill level below minimum is reported as LEVEL_TOO_LOW, absent skill as MISSING", () => {
  const g = graduate(AHMED);
  const o = { id: "x", type: "JOB", title: "t", skills: [
    { skill_id: "KOTLIN", importance: 3, min_level: 5, is_required: true },
    { skill_id: "GIT", importance: 3, min_level: 1, is_required: false }], eligibility_failures: [] };
  const a = skillAnalysis(g, o);
  assert.deepEqual(a.gaps.map((x) => [x.skill_id, x.reason]), [["KOTLIN", "LEVEL_TOO_LOW"], ["GIT", "MISSING"]]);
});

test("scores stay within 0..100 for every demo graduate x every opportunity", () => {
  for (const d of demo) for (const r of rankOpportunities(graduate(d.email), opps())) {
    assert.ok(r.score >= 0 && r.score <= 100, `${d.email} ${r.opportunity_id} ${r.score}`);
  }
});

test("criteria without input are excluded and weights renormalised", () => {
  const bare = { career_interests: [], experience_years: 0, skills: [{ skill_id: "KOTLIN", level: 5 }] };
  const o = { id: "j", type: "JOB", title: "Kotlin dev", status: "ACTIVE", skills: [{ skill_id: "KOTLIN", importance: 5, min_level: 3, is_required: true }], eligibility_failures: [] };
  const r = scoreOpportunity(bare, o)!;
  assert.equal(r.score_breakdown.interests, null);
  assert.equal(r.score_breakdown.location, null);
  assert.equal(r.score_breakdown.skills, 100);
  assert.ok(r.score > 0 && r.score <= 100);
});

test("ranking is deterministic and sorted descending", () => {
  const a = rankOpportunities(graduate(SARA), opps()), b = rankOpportunities(graduate(SARA), opps());
  assert.deepEqual(a, b);
  for (let i = 1; i < a.length; i++) assert.ok(a[i - 1].score >= a[i].score);
});

const NOW = new Date("2026-11-23T12:00:00Z");
const iso = (ms: number) => new Date(NOW.getTime() + ms).toISOString();
const training = (over: Record<string, unknown> = {}) => ({
  id: "t", type: "TRAINING", title: "Training", status: "ACTIVE", deadline: null, end_at: null,
  target_fields: [], skills: [], eligibility_failures: [],
  capacity: 10, registered_count: 0, waitlist_enabled: false, registration_opens_at: null, ...over,
});
const bareGraduate = { career_interests: [], experience_years: 0, skills: [] };

test("availability (issue #16): an upcoming training window is kept but scores 0", () => {
  const r = scoreOpportunity(bareGraduate, training({ registration_opens_at: iso(60_000) }), NOW)!;
  assert.equal(r.availability_status, "UPCOMING");
  assert.equal(r.score_breakdown.availability, 0);
  assert.equal(r.score, 0);
});

test("availability: open training with free capacity scores 1, waitlist-only scores 0.5", () => {
  const open = scoreOpportunity(bareGraduate, training(), NOW)!;
  assert.equal(open.availability_status, "OPEN");
  assert.equal(open.score_breakdown.availability, 100);
  assert.equal(open.score, 100);
  const wait = scoreOpportunity(bareGraduate, training({ registered_count: 10, waitlist_enabled: true }), NOW)!;
  assert.equal(wait.availability_status, "WAITLIST_ONLY");
  assert.equal(wait.score_breakdown.availability, 50);
  assert.equal(wait.score, 50);
});

test("availability: full training without a waitlist is never recommended", () => {
  assert.equal(scoreOpportunity(bareGraduate, training({ registered_count: 10 }), NOW), null);
  const ranked = rankOpportunities(bareGraduate, [training({ id: "full", registered_count: 12 })], NOW);
  assert.deepEqual(ranked, []);
});

test("availability: a closed opportunity is never scored, even when called directly", () => {
  assert.equal(scoreOpportunity(bareGraduate, training({ status: "CLOSED" }), NOW), null);
});

test("availability: opportunities without registration data keep the previous behaviour (null criterion)", () => {
  const job = { id: "j", type: "JOB", title: "Kotlin dev", status: "ACTIVE", deadline: null, end_at: null, skills: [], eligibility_failures: [] };
  const r = scoreOpportunity(bareGraduate, job, NOW)!;
  assert.equal(r.availability_status, null);
  assert.equal(r.score_breakdown.availability, undefined);
});

test("availability: a registration window that opened exactly now counts as open", () => {
  const r = scoreOpportunity(bareGraduate, training({ registration_opens_at: iso(0) }), NOW)!;
  assert.equal(r.availability_status, "OPEN");
});

test("availability: JOB and INTERNSHIP are never excluded or mislabelled by Training-only fields", () => {
  for (const type of ["JOB", "INTERNSHIP"]) {
    const item = scoreOpportunity(bareGraduate, {
      id: type, type, title: "Role", status: "ACTIVE", deadline: null, end_at: null,
      capacity: 1, registered_count: 9, waitlist_enabled: false,
      registration_opens_at: iso(60_000), skills: [], eligibility_failures: [],
    }, NOW);
    assert.ok(item, type);
    assert.equal(item.availability_status, null, type);
    assert.equal(item.score_breakdown.availability, undefined, type);
  }
  const ranked = rankOpportunities(bareGraduate, ["JOB", "INTERNSHIP"].map((type) => ({
    id: type, type, title: "Role", status: "ACTIVE", deadline: null, end_at: null,
    capacity: 1, registered_count: 9, waitlist_enabled: false,
    registration_opens_at: iso(60_000), skills: [], eligibility_failures: [],
  })), NOW);
  assert.deepEqual(ranked.map((r) => r.opportunity_id).sort(), ["INTERNSHIP", "JOB"]);
});

test("availability: universal closure drops a closed JOB even when called directly", () => {
  assert.equal(scoreOpportunity(bareGraduate, {
    id: "closed-job", type: "JOB", title: "Role", status: "CLOSED", deadline: null, end_at: null,
    capacity: 1, registered_count: 9, skills: [], eligibility_failures: [],
  }, NOW), null);
});

test("training suggests skills the graduate lacks (gap_fill)", () => {
  const r = rankOpportunities(graduate(SARA), opps()).find((x) => x.opportunity_id === "trn-python-data")!;
  assert.ok(r.missing_skill_ids.includes("PYTHON"));
});
