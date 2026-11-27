import { test } from "node:test";
import assert from "node:assert/strict";
import { extractSkillsFromText, validateExtraction } from "../supabase/functions/_shared/cv-extract.ts";
import { skills } from "./helpers.ts";

const dict = skills.map((s: any) => ({ id: s.id, canonical_name: s.name, aliases: s.aliases }));
const ids = (t: string) => extractSkillsFromText(t, dict).map((x) => x.skill_id).sort();

test("extracts canonical names and aliases", () => {
  assert.deepEqual(ids("Reporting in PowerBI with T-SQL and Microsoft Excel."), ["EXCEL", "POWER_BI", "SQL"]);
});
test("Java does not match JavaScript, and vice versa", () => {
  assert.deepEqual(ids("Frontend work in JavaScript and React.js"), ["JAVASCRIPT", "REACT"]);
  assert.deepEqual(ids("Backend in Java"), ["JAVA"]);
});
test("Node.js and React.js do not create JavaScript false positives from dotted suffix aliases", () => {
  assert.deepEqual(ids("Backend uses Node.js and React.js services"), ["NODE_JS", "REACT"]);
  assert.deepEqual(ids("Frontend JavaScript with Node.js runtime"), ["JAVASCRIPT", "NODE_JS"]);
  assert.deepEqual(ids("JS is an abbreviation used independently"), ["JAVASCRIPT"]);
});
test("symbols in names are handled (C#, C++, CI/CD)", () => {
  assert.deepEqual(ids("Wrote C# and C++ services, CI/CD with GitHub Actions"), ["CPP", "C_SHARP", "DEVOPS_CI_CD", "GIT"].sort() /* "GitHub" is a Git alias */);
});
test("no skills found in unrelated text, empty text is safe", () => {
  assert.deepEqual(ids("I enjoy hiking and painting."), []);
  assert.deepEqual(ids(""), []);
});
test("validateExtraction rejects unknown ids, bad levels, and dedupes", () => {
  const allowed = new Set(["KOTLIN", "SQL"]);
  const r = validateExtraction({ skills: [
    { skill_id: "KOTLIN", level: 4 }, { skill_id: "KOTLIN", level: 2 }, { skill_id: "HACKING_NASA" },
    { skill_id: "SQL", level: 9 }, { level: 3 }, { skill_id: "SQL" }] }, allowed);
  assert.deepEqual(r.skills, [{ skill_id: "KOTLIN", level: 4 }, { skill_id: "SQL" }]);
  assert.equal(r.errors.length, 3);
});
test("validateExtraction rejects non-object payloads", () => {
  assert.equal(validateExtraction("garbage", new Set()).errors.length, 1);
  assert.equal(validateExtraction(null, new Set()).skills.length, 0);
});

test("REGRESSION: Arabic-attached conjunction/preposition does not hide Latin skills", () => {
  // Arabic attaches و/ف/ب/ل directly to the next word; the DOCX benchmark missed SQL and Kotlin here.
  assert.deepEqual(ids("عمل على خدمات داخلية باستخدام Python وSQL وKotlin."), ["KOTLIN", "PYTHON", "SQL"]);
  assert.deepEqual(ids("استخدمت Docker وReact في المشروع"), ["DOCKER", "REACT"]);
  assert.deepEqual(ids("خبرة فيSQL وKotlin خلال التدريب"), ["KOTLIN", "SQL"]);
});

test("Arabic diacritics, tatweel and punctuation do not block a skill match", () => {
  assert.deepEqual(ids("مهاراتي في SQL، وKotlin؛ وDocker."), ["DOCKER", "KOTLIN", "SQL"]);
  assert.deepEqual(ids("استخدمت Kـotlin وPythـon"), ["KOTLIN", "PYTHON"]);
  assert.deepEqual(ids("أعمل على قواعد البيانات SQL\u200f"), ["SQL"]);
});

test("mixed-script boundaries never create substring skill false positives", () => {
  assert.deepEqual(ids("استخدمت SQLite فقط"), []);
  assert.deepEqual(ids("لا أستخدم JavaScript أو KotlinScript"), ["JAVASCRIPT"]);
  assert.deepEqual(ids("MySQL وPostgreSQL"), ["POSTGRESQL", "SQL"].sort());
  assert.deepEqual(ids("استخدمت AndroidX فقط"), []);
  assert.deepEqual(ids("واجهة Androيد ليست Web"), []);
});

test("normalization does not rewrite the matched term reported to the reviewer", () => {
  const found = extractSkillsFromText("خبرة في Kـotlin", dict);
  assert.equal(found.find((item) => item.skill_id === "KOTLIN")?.matched_term, "Kotlin");
});
