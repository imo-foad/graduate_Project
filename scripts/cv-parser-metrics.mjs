// Field-level metrics for the synthetic CV parser corpus (issue #24).
// Pure and deterministic: the HTTP evaluator and a local harness both use these functions, so the
// reported numbers do not depend on how a document reached the parser.

export const QUALITY_GATES = {
  skills: { precision: 0.95, recall: 0.95 },
  experience_fields: { precision: 0.9, recall: 0.9 },
  certification_fields: { precision: 0.95, recall: 0.95 },
  course_fields: { precision: 0.95, recall: 0.95 },
};

export const CATEGORIES = ["skills", "experience_fields", "certification_fields", "course_fields"];

const EXPERIENCE_KEYS = ["company_name", "job_title", "start_date", "end_date", "is_current"];
const CREDENTIAL_KEYS = ["title", "issuer", "issue_date", "duration"];

export function normalizeValue(value) {
  return String(value).trim().replace(/\s+/g, " ").toLowerCase();
}

export function experienceFields(rows) {
  return rows.flatMap((row) =>
    EXPERIENCE_KEYS.filter((key) => row?.[key] !== undefined && row?.[key] !== null)
      .map((key) => key + ":" + normalizeValue(row[key])));
}

export function credentialFields(rows) {
  return rows.flatMap((row) =>
    CREDENTIAL_KEYS.filter((key) => row?.[key] !== undefined && row?.[key] !== null)
      .map((key) => key + ":" + normalizeValue(row[key])));
}

export function scoreFields(expected, actual) {
  const expectedSet = new Set(expected);
  const actualSet = new Set(actual);
  const truePositive = [...expectedSet].filter((value) => actualSet.has(value));
  const falsePositive = [...actualSet].filter((value) => !expectedSet.has(value));
  const falseNegative = [...expectedSet].filter((value) => !actualSet.has(value));
  return {
    true_positive: truePositive.length,
    false_positive: falsePositive.length,
    false_negative: falseNegative.length,
    precision: truePositive.length / ((truePositive.length + falsePositive.length) || 1),
    recall: truePositive.length / ((truePositive.length + falseNegative.length) || 1),
    expected: expectedSet.size,
    actual: actualSet.size,
    false_positive_fields: falsePositive,
    missed_fields: falseNegative,
  };
}

/** Compare the parser's suggestions with one scenario's versioned ground truth. */
export function scoreScenario(scenario, actual) {
  const expected = scenario.expected ?? {};
  const metrics = {
    skills: scoreFields(expected.skills ?? [], actual.skills ?? []),
    experience_fields: scoreFields(experienceFields(expected.experiences ?? []), experienceFields(actual.experiences ?? [])),
    certification_fields: scoreFields(credentialFields(expected.certifications ?? []), credentialFields(actual.certifications ?? [])),
    course_fields: scoreFields(credentialFields(expected.courses ?? []), credentialFields(actual.courses ?? [])),
  };
  const forbidden = scenario.must_not_extract ?? {};
  const violations = [];
  const actualSkillIds = new Set(actual.skills ?? []);
  for (const skill of forbidden.skills ?? []) {
    if (actualSkillIds.has(skill)) violations.push({ category: "skills", value: skill });
  }
  const certificationText = credentialFields(actual.certifications ?? []).join(" | ");
  for (const title of forbidden.certifications ?? []) {
    if (certificationText.includes(normalizeValue(title))) violations.push({ category: "certifications", value: title });
  }
  const courseText = credentialFields(actual.courses ?? []).join(" | ");
  for (const title of forbidden.courses ?? []) {
    if (courseText.includes(normalizeValue(title))) violations.push({ category: "courses", value: title });
  }
  const totalActual = (actual.skills ?? []).length + (actual.experiences ?? []).length +
    (actual.certifications ?? []).length + (actual.courses ?? []).length;
  const categories = {
    skills_missed: metrics.skills.false_negative,
    skills_false_positive: metrics.skills.false_positive,
    experience_missed: metrics.experience_fields.false_negative,
    experience_false_positive: metrics.experience_fields.false_positive,
    certification_missed: metrics.certification_fields.false_negative,
    certification_false_positive: metrics.certification_fields.false_positive,
    course_missed: metrics.course_fields.false_negative,
    course_false_positive: metrics.course_fields.false_positive,
    negative_violation: violations.length,
    empty_result: totalActual === 0 ? 1 : 0,
  };
  return { metrics, violations, failure_categories: categories, total_suggestions: totalActual };
}

export function aggregateScores(scenarios) {
  const aggregate = {};
  for (const category of CATEGORIES) {
    const values = scenarios.map((scenario) => scenario.metrics[category]);
    const truePositive = values.reduce((sum, value) => sum + value.true_positive, 0);
    const falsePositive = values.reduce((sum, value) => sum + value.false_positive, 0);
    const falseNegative = values.reduce((sum, value) => sum + value.false_negative, 0);
    aggregate[category] = {
      true_positive: truePositive,
      false_positive: falsePositive,
      false_negative: falseNegative,
      precision: truePositive / ((truePositive + falsePositive) || 1),
      recall: truePositive / ((truePositive + falseNegative) || 1),
      f1: (2 * truePositive) / ((2 * truePositive + falsePositive + falseNegative) || 1),
    };
  }
  return aggregate;
}

/** Empty or malformed corpora must fail loudly rather than produce a flattering score. */
export function validateCorpus(corpus) {
  const errors = [];
  if (!corpus || typeof corpus !== "object") return ["corpus must be an object"];
  if (corpus.version !== 1) errors.push("unsupported corpus version");
  const scenarios = Array.isArray(corpus.scenarios) ? corpus.scenarios : null;
  if (!scenarios) return [...errors, "scenarios must be an array"];
  if (scenarios.length < 10) errors.push("corpus must contain at least 10 scenarios");
  const ids = new Set();
  let negativeScenarios = 0;
  for (const [index, scenario] of scenarios.entries()) {
    const label = `scenarios[${index}]`;
    if (!scenario || typeof scenario !== "object") { errors.push(label + " must be an object"); continue; }
    if (typeof scenario.id !== "string" || !/^[a-z0-9][a-z0-9-]*$/.test(scenario.id)) errors.push(label + " has an invalid id");
    if (ids.has(scenario.id)) errors.push("duplicate scenario id " + scenario.id);
    ids.add(scenario.id);
    if (!["pdf", "docx"].includes(scenario.format)) errors.push(scenario.id + " has an unsupported format");
    if (!Array.isArray(scenario.content) || scenario.content.length === 0) errors.push(scenario.id + " has no content");
    if (!scenario.expected || typeof scenario.expected !== "object") { errors.push(scenario.id + " has no expected annotations"); continue; }
    for (const key of ["skills", "experiences", "certifications", "courses"]) {
      if (!Array.isArray(scenario.expected[key])) errors.push(scenario.id + " expected." + key + " must be an array");
    }
    for (const skill of scenario.expected.skills ?? []) {
      if (typeof skill !== "string" || !/^[A-Z0-9_]+$/.test(skill)) errors.push(scenario.id + " has an invalid skill id " + skill);
    }
    const forbidden = scenario.must_not_extract ?? {};
    const expectedTotal = (scenario.expected.skills?.length ?? 0) + (scenario.expected.experiences?.length ?? 0) +
      (scenario.expected.certifications?.length ?? 0) + (scenario.expected.courses?.length ?? 0);
    const forbiddenTotal = (forbidden.skills?.length ?? 0) + (forbidden.certifications?.length ?? 0) + (forbidden.courses?.length ?? 0);
    if (expectedTotal === 0) {
      negativeScenarios++;
      if (forbiddenTotal === 0) errors.push(scenario.id + " has neither expectations nor forbidden fields");
    }
    if (scenario.format === "pdf" && JSON.stringify(scenario.content).match(/[^\x00-\x7F]/)) {
      errors.push(scenario.id + " puts non-ASCII text in a Latin-font PDF fixture");
    }
  }
  if (negativeScenarios === 0) errors.push("corpus must contain at least one negative scenario");
  return errors;
}

export function gateReport(aggregate) {
  const failures = [];
  for (const [category, gate] of Object.entries(QUALITY_GATES)) {
    const score = aggregate[category];
    if (!score) { failures.push(category + ": missing aggregate"); continue; }
    if (score.precision < gate.precision) failures.push(`${category}: precision ${(score.precision * 100).toFixed(1)}% < ${(gate.precision * 100).toFixed(0)}%`);
    if (score.recall < gate.recall) failures.push(`${category}: recall ${(score.recall * 100).toFixed(1)}% < ${(gate.recall * 100).toFixed(0)}%`);
  }
  return { passed: failures.length === 0, failures };
}
