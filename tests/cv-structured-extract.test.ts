import { test } from "node:test";
import assert from "node:assert/strict";
import { extractStructuredCvData } from "../supabase/functions/_shared/cv-structured-extract.ts";

const sample = [
  "SUMMARY",
  "Computer science graduate",
  "WORK EXPERIENCE",
  "Frontend Developer | Bright Apps",
  "Jan 2022 - Dec 2023",
  "Built responsive interfaces using React and TypeScript.",
  "CERTIFICATIONS",
  "AWS Certified Cloud Practitioner | Amazon Web Services | 2024",
  "COURSES",
  "Advanced TypeScript | Coursera | 2023 | 8 weeks",
  "EDUCATION",
  "BSc Computer Science",
  "PROJECTS",
  "Portfolio website",
].join("\n");

test("extracts experience with employer, job title, dates and description", () => {
  const result = extractStructuredCvData(sample);
  assert.equal(result.experiences.length, 1);
  assert.equal(result.experiences[0].company_name, "Bright Apps");
  assert.equal(result.experiences[0].job_title, "Frontend Developer");
  assert.equal(result.experiences[0].start_date, "2022-01-01");
  assert.equal(result.experiences[0].end_date, "2023-12-31");
  assert.match(result.experiences[0].description ?? "", /responsive interfaces/);
});
test("extracts certifications and courses separately", () => {
  const result = extractStructuredCvData(sample);
  assert.equal(result.certifications[0].title, "AWS Certified Cloud Practitioner");
  assert.equal(result.certifications[0].issuer, "Amazon Web Services");
  assert.equal(result.certifications[0].issue_date, "2024-01-01");
  assert.equal(result.courses[0].title, "Advanced TypeScript");
  assert.equal(result.courses[0].issuer, "Coursera");
  assert.equal(result.courses[0].duration, "8 weeks");
});
test("does not parse education or projects as career records", () => {
  const result = extractStructuredCvData(sample);
  assert.equal(result.experiences.some((item) => item.raw_text.includes("BSc Computer Science")), false);
  assert.equal(result.courses.some((item) => item.title.includes("Portfolio")), false);
});
test("handles a current position and a missing end date", () => {
  const result = extractStructuredCvData([
    "EXPERIENCE", "Backend Developer | Example Labs", "2024 - Present",
  ].join("\n"));
  assert.equal(result.experiences[0].is_current, true);
  assert.equal(result.experiences[0].end_date, undefined);
});
