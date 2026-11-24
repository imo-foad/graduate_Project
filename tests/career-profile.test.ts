import { test } from "node:test";
import assert from "node:assert/strict";
import { deriveCareerProfile } from "../supabase/functions/_shared/career-profile.ts";

const skills = (...ids: string[]) => ids.map((skill_id) => ({ skill_id, level: 4 }));

test("identifies Frontend from core web stack and exposes evidence plus next skills", () => {
  const result = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 4 },
    { skill_id: "JAVASCRIPT", level: 5 },
    { skill_id: "REACT", level: 3 },
    { skill_id: "GIT", level: 4 },
  ]);
  const frontend = result.paths.find((item) => item.id === "FRONTEND");
  assert.ok(frontend);
  assert.equal(result.primary_path?.id, "FRONTEND");
  assert.deepEqual(frontend.matched_core_skill_ids, ["HTML_CSS", "JAVASCRIPT", "REACT"]);
  assert.deepEqual(frontend.matched_supporting_skill_ids, ["GIT"]);
  assert.deepEqual(frontend.missing_core_skill_ids, ["TYPESCRIPT"]);
  assert.deepEqual(frontend.next_skill_ids, ["TYPESCRIPT"]);
  assert.equal(frontend.core_match_count, 3);
  assert.equal(frontend.required_core_match_count, 2);
  assert.ok(frontend.skill_evidence.every((item) => item.contribution > 0));
  assert.match(frontend.explanation_ar, /مهارات أساسية/);
});

test("identifies Backend from API and database evidence, not generic languages alone", () => {
  const result = deriveCareerProfile([
    ...skills("NODE_JS", "REST_API", "POSTGRESQL"),
    { skill_id: "PYTHON", level: 5 },
  ]);
  const backend = result.paths.find((item) => item.id === "BACKEND");
  assert.ok(backend);
  assert.deepEqual(backend.matched_core_skill_ids, ["NODE_JS", "REST_API", "POSTGRESQL"]);
  assert.ok(backend.matched_supporting_skill_ids.includes("PYTHON"));

  const generic = deriveCareerProfile(skills("JAVA", "PYTHON"));
  assert.equal(generic.paths.some((item) => item.id === "BACKEND"), false);
});

test("recognises a Java-based Backend stack when paired with a core backend capability", () => {
  const result = deriveCareerProfile(skills("JAVA", "API_DESIGN", "MONGODB"));
  assert.ok(result.paths.some((item) => item.id === "BACKEND"));
});

test("recognises Data Analytics from analytics and visualization skills", () => {
  const result = deriveCareerProfile(skills("SQL", "POWER_BI", "STATISTICS", "DATA_VISUALIZATION"));
  const data = result.paths.find((item) => item.id === "DATA_ANALYTICS");
  assert.ok(data);
  assert.equal(result.primary_path?.id, "DATA_ANALYTICS");
});

test("recognises Data Science separately from general analytics", () => {
  const result = deriveCareerProfile(skills("PYTHON", "STATISTICS", "MACHINE_LEARNING", "ETL"));
  assert.ok(result.paths.some((item) => item.id === "DATA_SCIENCE"));
  assert.equal(result.paths.some((item) => item.id === "DATA_ANALYTICS"), false);
});

test("recognises Cybersecurity from security-specific core evidence", () => {
  const result = deriveCareerProfile(skills("CYBERSECURITY", "PENETRATION_TESTING", "NETWORKING"));
  const cyber = result.paths.find((item) => item.id === "CYBERSECURITY");
  assert.ok(cyber);
  assert.equal(result.primary_path?.id, "CYBERSECURITY");
});

test("supports multiple independent paths for one graduate and ranks all of them", () => {
  const result = deriveCareerProfile([
    ...skills("NODE_JS", "REST_API", "POSTGRESQL"),
    ...skills("SQL", "POWER_BI", "STATISTICS"),
  ]);
  const ids = result.paths.map((item) => item.id);
  assert.ok(ids.includes("BACKEND"));
  assert.ok(ids.includes("DATA_ANALYTICS"));
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(result.primary_path?.id, result.paths[0]?.id);
  assert.deepEqual(ids, [...ids].sort((a, b) => {
    const left = result.paths.find((item) => item.id === a)!;
    const right = result.paths.find((item) => item.id === b)!;
    return right.score - left.score ||
      right.core_match_count - left.core_match_count ||
      right.matched_skill_ids.length - left.matched_skill_ids.length ||
      left.id.localeCompare(right.id);
  }));
});

test("does not infer Backend from general-purpose languages without backend architecture evidence", () => {
  const result = deriveCareerProfile(skills("JAVA", "C_SHARP", "PYTHON"));
  assert.equal(result.paths.some((item) => item.id === "BACKEND"), false);
  const javaApi = deriveCareerProfile(skills("JAVA", "REST_API"));
  const backend = javaApi.paths.find((item) => item.id === "BACKEND");
  assert.ok(backend);
  assert.deepEqual(backend.specialization_signal_skill_ids, ["REST_API"]);
});

test("does not infer Data Science from generic analytics skills without a science signal", () => {
  const analyticsOnly = deriveCareerProfile(skills("STATISTICS", "DATA_CLEANING", "SQL"));
  assert.equal(analyticsOnly.paths.some((item) => item.id === "DATA_SCIENCE"), false);
  const science = deriveCareerProfile(skills("PYTHON", "STATISTICS"));
  assert.ok(science.paths.some((item) => item.id === "DATA_SCIENCE"));
});

test("does not infer Cybersecurity from networking alone without security-specific evidence", () => {
  const result = deriveCareerProfile(skills("NETWORKING", "LINUX", "DOCKER"));
  assert.equal(result.paths.some((item) => item.id === "CYBERSECURITY"), false);
  const cyber = deriveCareerProfile(skills("NETWORKING", "SIEM"));
  const match = cyber.paths.find((item) => item.id === "CYBERSECURITY");
  assert.ok(match);
  assert.deepEqual(match.specialization_signal_skill_ids, ["SIEM"]);
});

test("does not force a path from one isolated core skill or shared prerequisites", () => {
  for (const profile of [
    [{ skill_id: "HTML_CSS", level: 5 }],
    skills("CYBERSECURITY", "LINUX"),
    skills("NETWORKING", "DOCKER"),
    skills("JAVA", "PYTHON"),
  ]) {
    const result = deriveCareerProfile(profile);
    assert.equal(result.primary_path, null);
    assert.deepEqual(result.paths, []);
  }
});

test("higher skill levels increase a path score and missing skills reduce coverage", () => {
  const beginner = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 1 }, { skill_id: "JAVASCRIPT", level: 1 },
  ]).paths.find((item) => item.id === "FRONTEND")!;
  const advanced = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 5 }, { skill_id: "JAVASCRIPT", level: 5 },
  ]).paths.find((item) => item.id === "FRONTEND")!;
  const complete = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 5 }, { skill_id: "JAVASCRIPT", level: 5 },
    { skill_id: "TYPESCRIPT", level: 5 }, { skill_id: "REACT", level: 5 },
  ]).paths.find((item) => item.id === "FRONTEND")!;
  assert.ok(beginner.score < advanced.score);
  assert.ok(advanced.score < complete.score);
  assert.ok(beginner.score >= 0 && complete.score <= 100);
});

test("deduplicates skills using the highest valid level and ignores malformed evidence", () => {
  const result = deriveCareerProfile([
    { skill_id: " html_css ", level: 2 },
    { skill_id: "HTML_CSS", level: 5 },
    { skill_id: "JAVASCRIPT", level: 4 },
    { skill_id: "REACT", level: 0 },
    { skill_id: "TYPESCRIPT", level: 99 },
    { skill_id: "UNKNOWN_SKILL", level: 5 },
    { skill_id: "GIT", level: Number.NaN },
  ]);
  const frontend = result.paths.find((item) => item.id === "FRONTEND")!;
  assert.deepEqual(frontend.matched_core_skill_ids, ["HTML_CSS", "JAVASCRIPT", "TYPESCRIPT"]);
  assert.deepEqual(frontend.skill_evidence.map((item) => item.level), [5, 4, 5]);
  assert.ok(frontend.score <= 100);
});

test("returns every credible path rather than truncating at four", () => {
  const allSkillIds = [
    "HTML_CSS", "JAVASCRIPT", "TYPESCRIPT", "REACT", "GIT",
    "NODE_JS", "REST_API", "API_DESIGN", "POSTGRESQL", "MONGODB", "JAVA", "C_SHARP", "PYTHON", "DOCKER", "LINUX",
    "KOTLIN", "ANDROID", "JETPACK_COMPOSE", "FLUTTER",
    "SQL", "POWER_BI", "EXCEL", "STATISTICS", "DATA_VISUALIZATION", "TABLEAU", "DATA_CLEANING", "MACHINE_LEARNING", "ETL",
    "CYBERSECURITY", "PENETRATION_TESTING", "SIEM", "NETWORKING", "CRYPTOGRAPHY", "AWS", "CLOUD_BASICS", "DEVOPS_CI_CD",
    "TESTING", "UI_UX", "FIGMA",
  ];
  const result = deriveCareerProfile(skills(...allSkillIds));
  assert.equal(result.paths.length, 9);
  assert.equal(new Set(result.paths.map((item) => item.id)).size, 9);
  assert.deepEqual(result.primary_path, result.paths[0]);
});

test("all four requested tracks satisfy the exact two-core threshold; supporting skills cannot replace a core", () => {
  const cases = [
    { id: "FRONTEND", core: ["HTML_CSS", "JAVASCRIPT"], support: "GIT" },
    { id: "BACKEND", core: ["NODE_JS", "REST_API"], support: "DOCKER" },
    { id: "DATA_ANALYTICS", core: ["SQL", "POWER_BI"], support: "PYTHON" },
    { id: "CYBERSECURITY", core: ["CYBERSECURITY", "PENETRATION_TESTING"], support: "LINUX" },
  ];
  for (const scenario of cases) {
    const valid = deriveCareerProfile([
      { skill_id: scenario.core[0], level: 1 },
      { skill_id: scenario.core[1], level: 1 },
      { skill_id: scenario.support, level: 5 },
    ]);
    assert.ok(valid.paths.some((item) => item.id === scenario.id), scenario.id + " must accept exactly two core skills");
    const invalid = deriveCareerProfile([
      { skill_id: scenario.core[0], level: 5 },
      { skill_id: scenario.support, level: 5 },
    ]);
    assert.equal(invalid.paths.some((item) => item.id === scenario.id), false,
      scenario.id + " must not substitute a supporting skill for a missing core skill");
  }
});

test("reported skill contributions reconcile with the weighted path score", () => {
  const result = deriveCareerProfile([
    { skill_id: "HTML_CSS", level: 5 },
    { skill_id: "JAVASCRIPT", level: 3 },
    { skill_id: "REACT", level: 2 },
    { skill_id: "GIT", level: 4 },
  ]);
  const frontend = result.paths.find((item) => item.id === "FRONTEND")!;
  const contributionTotal = frontend.skill_evidence.reduce((sum, item) => sum + item.contribution, 0);
  assert.ok(Math.abs(contributionTotal - frontend.score) <= 0.51,
    "per-skill contributions should reconcile to the rounded score");
  assert.ok(frontend.next_skill_ids.length <= 3);
  assert.ok(frontend.next_skill_ids.every((id) => frontend.missing_core_skill_ids.includes(id)));
});

test("ranking is deterministic regardless of input skill order", () => {
  const profile = ["SQL", "POWER_BI", "STATISTICS", "NODE_JS", "REST_API", "POSTGRESQL"];
  const forward = deriveCareerProfile(skills(...profile));
  const reverse = deriveCareerProfile(skills(...profile.slice().reverse()));
  assert.deepEqual(forward, reverse);
});

test("empty and unrecognized profiles are explicit, non-null API objects", () => {
  const result = deriveCareerProfile([{ skill_id: "NOT_IN_CATALOGUE", level: 5 }]);
  assert.equal(result.primary_path, null);
  assert.deepEqual(result.paths, []);
  assert.match(result.disclaimer, /ليست احتمال قبول/);
});
