import { test } from "node:test";
import assert from "node:assert/strict";
import {
  aggregateScores,
  credentialFields,
  experienceFields,
  gateReport,
  scoreFields,
  scoreScenario,
  validateCorpus,
} from "../scripts/cv-parser-metrics.mjs";

const scenario = {
  id: "unit-scenario",
  format: "docx",
  content: [{ line: "x" }],
  expected: {
    skills: ["SQL", "KOTLIN"],
    experiences: [{ company_name: "Bright Analytics", job_title: "Product Analyst", start_date: "2019-01-01" }],
    certifications: [{ title: "AWS Certified Developer", issuer: "Amazon Web Services" }],
    courses: [],
  },
  must_not_extract: { skills: ["JAVA"] },
};

test("field-level metrics count TP, FP and FN exactly", () => {
  const result = scoreFields(["a", "b"], ["b", "c", "c"]);
  assert.equal(result.true_positive, 1);
  assert.equal(result.false_positive, 1);
  assert.equal(result.false_negative, 1);
  assert.equal(result.precision, 0.5);
  assert.equal(result.recall, 0.5);
});

test("experience and credential fields are normalized and only include present values", () => {
  assert.deepEqual(experienceFields([{ company_name: "  Bright   Analytics ", start_date: "2019-01-01" }]),
    ["company_name:bright analytics", "start_date:2019-01-01"]);
  assert.deepEqual(credentialFields([{ title: "Course", duration: "6  hours" }]), ["title:course", "duration:6 hours"]);
});

test("a perfect scenario scores 1.0 in every category", () => {
  const actual = {
    skills: ["KOTLIN", "SQL"],
    experiences: [{ company_name: "Bright Analytics", job_title: "Product Analyst", start_date: "2019-01-01" }],
    certifications: [{ title: "AWS Certified Developer", issuer: "Amazon Web Services" }],
    courses: [],
  };
  const scored = scoreScenario(scenario, actual);
  assert.equal(scored.metrics.skills.precision, 1);
  assert.equal(scored.metrics.experience_fields.recall, 1);
  assert.deepEqual(scored.violations, []);
});

test("a forbidden skill is reported as a negative violation", () => {
  const scored = scoreScenario(scenario, { skills: ["JAVA"], experiences: [], certifications: [], courses: [] });
  assert.deepEqual(scored.violations, [{ category: "skills", value: "JAVA" }]);
  assert.equal(scored.failure_categories.negative_violation, 1);
});

test("an empty scenario cannot inflate the aggregate", () => {
  const empty = scoreScenario(scenario, { skills: [], experiences: [], certifications: [], courses: [] });
  const aggregate = aggregateScores([empty]);
  assert.equal(aggregate.skills.recall, 0);
  assert.equal(aggregate.experience_fields.recall, 0);
  assert.equal(gateReport(aggregate).passed, false);
});

test("quality gates fail below the declared per-field thresholds", () => {
  const aggregate = {
    skills: { precision: 0.949, recall: 1 },
    experience_fields: { precision: 1, recall: 0.899 },
    certification_fields: { precision: 0.96, recall: 0.96 },
    course_fields: { precision: 1, recall: 1 },
  };
  const report = gateReport(aggregate);
  assert.equal(report.passed, false);
  assert.equal(report.failures.length, 2);
});

test("corpus validation rejects missing, empty and duplicate fixtures", () => {
  assert.ok(validateCorpus(null).length > 0);
  assert.ok(validateCorpus({ version: 1, scenarios: [] }).length > 0);
  const malformed = {
    version: 1,
    scenarios: [
      { id: "a", format: "pdf", content: [], expected: { skills: ["SQL"], experiences: [], certifications: [], courses: [] } },
      { id: "a", format: "txt", content: [{ line: "x" }], expected: { skills: [], experiences: [], certifications: [], courses: [] } },
    ],
  };
  const errors = validateCorpus(malformed).join("\n");
  assert.match(errors, /at least 10 scenarios/);
  assert.match(errors, /has no content/);
  assert.match(errors, /duplicate scenario id/);
  assert.match(errors, /unsupported format/);
  assert.match(errors, /neither expectations nor forbidden/);
});

test("corpus validation accepts the committed synthetic corpus", async () => {
  const { readFileSync } = await import("node:fs");
  const corpus = JSON.parse(readFileSync(new URL("./fixtures/cv-parser/corpus.v1.json", import.meta.url), "utf8"));
  assert.deepEqual(validateCorpus(corpus), []);
  assert.ok(corpus.scenarios.length >= 10);
});
