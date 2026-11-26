import { test } from "node:test";
import assert from "node:assert/strict";
import { scoreOpportunity, weightProfile } from "../supabase/functions/_shared/scoring.ts";

test("all active recommendation families keep weights normalised", () => {
  for (const type of ["JOB","INTERNSHIP","TRAINING"]) {
    const total = Object.values(weightProfile(type)).reduce((sum, weight) => sum + (weight ?? 0), 0);
    assert.equal(total, 100, type);
  }
  for (const type of ["EVENT","CONFERENCE","VOLUNTEER","SCHOLARSHIP","COMPETITION"]) {
    assert.deepEqual(weightProfile(type), {}, type);
  }
});
test("an explicitly mandatory five-year requirement excludes a two-year graduate", () => {
  const item = scoreOpportunity(
    { career_interests: ["FRONTEND"], experience_years: 2, skills: [{ skill_id: "JAVASCRIPT", level: 4 }] },
    { id: "job", type: "JOB", title: "Frontend Developer", status: "ACTIVE", deadline: null, end_at: null, minimum_experience_years: 5,
      minimum_experience_required: true, skills: [], eligibility_failures: [] },
  );
  assert.equal(item, null);
});
test("a preferred, non-mandatory experience requirement reduces match instead of excluding", () => {
  const item = scoreOpportunity(
    { career_interests: ["FRONTEND"], experience_years: 2, skills: [{ skill_id: "JAVASCRIPT", level: 4 }] },
    { id: "job", type: "JOB", title: "Frontend Developer", status: "ACTIVE", deadline: null, end_at: null, minimum_experience_years: 5,
      minimum_experience_required: false, skills: [], eligibility_failures: [] },
  );
  assert.ok(item);
  assert.ok((item.score_breakdown.experience ?? 100) < 100);
});
test("positive interaction signals influence recommendations when opportunity fields match", () => {
  const base = { career_interests: [], experience_years: 0, skills: [], inferred_career_paths: [] as string[] };
  const opportunity = { id: "training", type: "TRAINING", title: "Frontend training", status: "ACTIVE", deadline: null, end_at: null, target_fields: ["Frontend"], skills: [], eligibility_failures: [] };
  const without = scoreOpportunity(base, opportunity)!;
  const withSignal = scoreOpportunity({ ...base, interaction_signals: [{ target_field: "frontend", weight: 2 }] }, opportunity)!;
  assert.ok(withSignal.score > without.score);
});
