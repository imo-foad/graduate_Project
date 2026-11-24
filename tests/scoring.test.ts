import { test } from "node:test";
import assert from "node:assert/strict";
import { rankOpportunities, scoreOpportunity, weightProfile, bandOf, skillAnalysis } from "../supabase/functions/_shared/scoring.ts";
import { demo, graduate, opps } from "./helpers.ts";

const AHMED = "graduate.android@alumni.test", SARA = "graduate.demo@alumni.test", OMAR = "graduate.cyber@alumni.test";

test("every weight profile sums to 100", () => {
  for (const t of ["JOB", "INTERNSHIP", "TRAINING", "EVENT", "CONFERENCE", "COMPETITION"]) {
    const sum = Object.values(weightProfile(t)).reduce((a, b) => a + (b ?? 0), 0);
    assert.equal(sum, 100, t);
  }
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
  const o = { id: "j", type: "JOB", title: "Kotlin dev", skills: [{ skill_id: "KOTLIN", importance: 5, min_level: 3, is_required: true }], eligibility_failures: [] };
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

test("training suggests skills the graduate lacks (gap_fill)", () => {
  const r = rankOpportunities(graduate(SARA), opps()).find((x) => x.opportunity_id === "trn-python-data")!;
  assert.ok(r.missing_skill_ids.includes("PYTHON"));
});
