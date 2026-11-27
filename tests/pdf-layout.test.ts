import { test } from "node:test";
import assert from "node:assert/strict";
import { layoutPdfText, type PdfTextItem } from "../supabase/functions/_shared/pdf-layout.ts";

// Synthetic positioned items, equivalent to what PDF.js returns: one item per visual text run.
const item = (str: string, x: number, y: number, width = str.length * 5.5, height = 11): PdfTextItem =>
  ({ str, x, y, width, height });

function singleColumn(raw: string[]): PdfTextItem[] {
  return raw.map((line, index) => item(line, 50, 760 - index * 14));
}

test("single-column pages keep reading order and section boundaries", () => {
  const text = layoutPdfText(singleColumn([
    "WORK EXPERIENCE", "Backend Engineer | Northstar", "Jan 2021 - Feb 2023", "Built APIs with Python.",
    "CERTIFICATIONS", "AWS Certified Cloud Practitioner | Amazon | 2023",
  ]));
  assert.equal(text, [
    "WORK EXPERIENCE", "Backend Engineer | Northstar", "Jan 2021 - Feb 2023", "Built APIs with Python.",
    "CERTIFICATIONS", "AWS Certified Cloud Practitioner | Amazon | 2023",
  ].join("\n"));
});

test("a wide gap between employer and title becomes an explicit field boundary", () => {
  // Employer on the left and job title on the right of the same visual line (two runs, one baseline).
  const text = layoutPdfText([
    item("EXPERIENCE", 50, 760),
    item("Bright Analytics", 50, 746),
    item("Product Analyst", 360, 746),
    item("2019 - 2020", 50, 732),
    item("Analysed product reports with SQL.", 50, 718),
  ]);
  const lines = text.split("\n");
  assert.equal(lines[0], "EXPERIENCE");
  assert.equal(lines[1], "Bright Analytics | Product Analyst");
  assert.equal(lines[2], "2019 - 2020");
  assert.equal(lines[3], "Analysed product reports with SQL.");
});

test("word-sized gaps inside one run stay normal spaces", () => {
  const text = layoutPdfText([
    item("Built", 50, 760, 26), item("REST", 79, 760, 24), item("services", 106, 760, 40),
  ]);
  assert.equal(text, "Built REST services");
});

test("a stable two-column page is emitted column by column, never interleaved", () => {
  const left = [
    "WORK EXPERIENCE",
    "Backend Engineer | Northstar Systems",
    "Jan 2021 - Feb 2023",
    "Built internal services with Python and SQL.",
  ];
  const right = ["SKILLS", "Kotlin", "Docker", "PostgreSQL", "CERTIFICATIONS"];
  const items: PdfTextItem[] = [];
  left.forEach((line, index) => items.push(item(line, 50, 760 - index * 14)));
  right.forEach((line, index) => items.push(item(line, 340, 760 - index * 14)));
  items.sort((a, b) => (b.y - a.y) || (a.x - b.x));
  const text = layoutPdfText(items);
  const lines = text.split("\n");
  assert.deepEqual(lines.slice(0, 4), left);
  assert.deepEqual(lines.slice(4), right);
  assert.equal(lines.some((line) => line.includes("Systems | SKILLS")), false);
});

test("right-aligned dates are kept on their job-title line instead of becoming a column", () => {
  const rows: Array<[string, string | null]> = [
    ["WORK EXPERIENCE", null],
    ["Product Analyst | Bright Analytics", "2020 - 2021"],
    ["Data Analyst | Insight Analytics", "2021 - Present"],
    ["Backend Engineer | Northstar Systems", "2021 - 2022"],
  ];
  const items: PdfTextItem[] = [];
  rows.forEach(([leftText, rightText], index) => {
    const y = 760 - index * 14;
    items.push(item(leftText, 50, y));
    if (rightText) items.push(item(rightText, 460, y));
  });
  const lines = layoutPdfText(items).split("\n");
  assert.deepEqual(lines, rows.map(([leftText, rightText]) => rightText ? leftText + " | " + rightText : leftText));
  assert.equal(lines[0], "WORK EXPERIENCE");
  assert.equal(lines[1].includes("Bright Analytics"), true);
  assert.equal(lines[2].startsWith("Data Analyst"), true);
});

test("an empty or whitespace-only page produces no text", () => {
  assert.equal(layoutPdfText([]), "");
  assert.equal(layoutPdfText([item("   ", 50, 760, 10)]), "");
});
