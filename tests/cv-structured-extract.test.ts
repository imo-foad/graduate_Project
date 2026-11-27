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

test("DOCX table rows keep employer, title and dates as one entry", () => {
  // The DOCX extractor joins table cells with " | " and the row ends the line.
  const result = extractStructuredCvData([
    "WORK EXPERIENCE",
    "Backend Engineer | Northstar Systems | Jan 2021 - Feb 2023",
    "Built services with Python.",
    "Data Analyst | Insight Analytics | 2020 - 2021",
    "Prepared reports with SQL.",
  ].join("\n"));
  assert.equal(result.experiences.length, 2);
  assert.equal(result.experiences[0].company_name, "Northstar Systems");
  assert.equal(result.experiences[0].job_title, "Backend Engineer");
  assert.equal(result.experiences[0].start_date, "2021-01-01");
  assert.equal(result.experiences[1].company_name, "Insight Analytics");
  assert.equal(result.experiences[1].job_title, "Data Analyst");
});

test("a two-line employer/title header is not merged or dropped", () => {
  const result = extractStructuredCvData([
    "EXPERIENCE", "Product Analyst", "Bright Analytics", "2019 - 2020", "Analysed product reports with SQL.",
  ].join("\n"));
  assert.equal(result.experiences.length, 1);
  assert.equal(result.experiences[0].job_title, "Product Analyst");
  assert.equal(result.experiences[0].company_name, "Bright Analytics");
  assert.equal(result.experiences[0].start_date, "2019-01-01");
  assert.equal(result.experiences[0].end_date, "2020-12-31");
  assert.match(result.experiences[0].description ?? "", /Analysed product reports/);
});

test("a description line is not mistaken for an employer name", () => {
  const result = extractStructuredCvData([
    "EXPERIENCE", "Backend Engineer", "Built REST API services", "2020 - 2021",
  ].join("\n"));
  assert.equal(result.experiences.length, 1);
  assert.equal(result.experiences[0].job_title, "Backend Engineer");
  assert.equal(result.experiences[0].company_name, undefined);
  assert.match(result.experiences[0].description ?? "", /Built REST API services/);
});

test("Arabic headings and table-style rows are recognized", () => {
  const result = extractStructuredCvData([
    "السيرة المهنية",
    "الخبرة العملية", "مهندس برمجيات | شركة النور | 03/2020 - 11/2021",
    "عمل على خدمات داخلية باستخدام Python وSQL وKotlin.",
    "الشهادات", "شهادة الأمن السيبراني | أكاديمية التقنية | 2022",
    "الدورات التدريبية", "تحليل البيانات | منصة التعلم | 2023 | 6 weeks",
  ].join("\n"));
  assert.equal(result.experiences.length, 1);
  assert.equal(result.experiences[0].job_title, "مهندس برمجيات");
  assert.equal(result.experiences[0].company_name, "شركة النور");
  assert.equal(result.experiences[0].start_date, "2020-03-01");
  assert.equal(result.certifications[0].title, "شهادة الأمن السيبراني");
  assert.equal(result.certifications[0].issuer, "أكاديمية التقنية");
  assert.equal(result.courses[0].title, "تحليل البيانات");
});

test("placeholder and non-credential lines are not emitted as credentials", () => {
  const result = extractStructuredCvData([
    "CERTIFICATIONS", "None", "N/A", "—", "COURSES", "لا يوجد",
  ].join("\n"));
  assert.deepEqual(result.certifications, []);
  assert.deepEqual(result.courses, []);
});
