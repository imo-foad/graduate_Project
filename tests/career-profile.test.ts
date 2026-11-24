import { test } from "node:test";
import assert from "node:assert/strict";
import { deriveCareerProfile } from "../supabase/functions/_shared/career-profile.ts";

test("recognises a frontend path from multiple confirmed web skills", () => {
  const result = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 2 }, { skill_id: "JAVASCRIPT", level: 3 }, { skill_id: "REACT", level: 2 },
  ]);
  assert.equal(result.primary_path?.id, "FRONTEND");
  assert.ok(result.paths.some((path) => path.id === "FRONTEND"));
});
test("does not force a career path from one isolated skill", () => {
  const result = deriveCareerProfile([{ skill_id: "HTML_CSS", level: 4 }]);
  assert.equal(result.primary_path, null);
});
test("can return more than one credible path", () => {
  const result = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 3 }, { skill_id: "JAVASCRIPT", level: 3 },
    { skill_id: "PYTHON", level: 2 }, { skill_id: "SQL", level: 3 }, { skill_id: "STATISTICS", level: 2 },
  ]);
  assert.ok(result.paths.length >= 2);
});
