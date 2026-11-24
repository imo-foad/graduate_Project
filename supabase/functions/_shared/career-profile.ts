// Explainable, deterministic career-path inference using only confirmed catalogue skills.
// Core skills carry 3x the weight of supporting skills. No external AI or paid API is used.
import type { GradSkill } from "./scoring.ts";

export interface CareerSkillEvidence {
  skill_id: string;
  level: number;
  role: "CORE" | "SUPPORTING";
  weight: number;
  contribution: number;
}

export interface CareerPathMatch {
  id: string;
  label: string;
  score: number;
  matched_skill_ids: string[];
  matched_core_skill_ids: string[];
  matched_supporting_skill_ids: string[];
  specialization_signal_skill_ids: string[];
  missing_core_skill_ids: string[];
  next_skill_ids: string[];
  core_match_count: number;
  required_core_match_count: number;
  skill_evidence: CareerSkillEvidence[];
  explanation_ar: string;
}

export interface CareerProfile {
  primary_path: CareerPathMatch | null;
  paths: CareerPathMatch[];
  disclaimer: string;
}

type PathSkill = {
  id: string;
  role: "CORE" | "SUPPORTING";
  weight: number;
};

interface PathDefinition {
  id: string;
  label: string;
  skills: PathSkill[];
  minimum_core_matches: number;
  required_core_any_skill_ids: string[];
}

const core = (id: string): PathSkill => ({ id, role: "CORE", weight: 3 });
const supporting = (id: string): PathSkill => ({ id, role: "SUPPORTING", weight: 1 });
const path = (
  id: string,
  label: string,
  coreIds: string[],
  supportingIds: string[] = [],
  minimumCoreMatches = 2,
  requiredCoreAnySkillIds: string[] = [],
): PathDefinition => ({
  id,
  label,
  skills: [...coreIds.map(core), ...supportingIds.map(supporting)],
  minimum_core_matches: minimumCoreMatches,
  required_core_any_skill_ids: requiredCoreAnySkillIds,
});

// A path is surfaced only when at least two of its core skills are present.
// General-purpose languages/tools are supporting evidence where they do not identify a path alone.
const PATHS: PathDefinition[] = [
  path("FRONTEND", "Frontend Development",
    ["HTML_CSS", "JAVASCRIPT", "TYPESCRIPT", "REACT"], ["GIT"]),
  path("BACKEND", "Backend Development",
    ["NODE_JS", "REST_API", "API_DESIGN", "POSTGRESQL", "MONGODB", "JAVA", "C_SHARP", "PYTHON"],
    ["DOCKER", "LINUX"], 2, ["NODE_JS", "REST_API", "API_DESIGN", "POSTGRESQL", "MONGODB"]),
  path("MOBILE", "Mobile Development",
    ["KOTLIN", "ANDROID", "JETPACK_COMPOSE", "FLUTTER"], ["JAVA"]),
  path("DATA_ANALYTICS", "Data Analytics",
    ["SQL", "POWER_BI", "EXCEL", "STATISTICS", "DATA_VISUALIZATION", "TABLEAU", "DATA_CLEANING"],
    ["PYTHON", "POSTGRESQL", "ETL"]),
  path("DATA_SCIENCE", "Data Science / Machine Learning",
    ["PYTHON", "STATISTICS", "MACHINE_LEARNING", "DATA_CLEANING", "ETL"],
    ["SQL", "DATA_VISUALIZATION"], 2, ["PYTHON", "MACHINE_LEARNING", "ETL"]),
  path("CYBERSECURITY", "Cybersecurity",
    ["CYBERSECURITY", "PENETRATION_TESTING", "SIEM", "NETWORKING", "CRYPTOGRAPHY"],
    ["LINUX", "DOCKER", "AWS"], 2, ["CYBERSECURITY", "PENETRATION_TESTING", "SIEM", "CRYPTOGRAPHY"]),
  path("DEVOPS_CLOUD", "DevOps & Cloud",
    ["DOCKER", "LINUX", "AWS", "CLOUD_BASICS", "DEVOPS_CI_CD"], ["NETWORKING"]),
  path("QA_AUTOMATION", "QA & Test Automation",
    ["TESTING", "JAVASCRIPT"], ["JAVA", "PYTHON"]),
  path("UI_UX", "UI/UX Design",
    ["UI_UX", "FIGMA"], ["HTML_CSS"]),
];

const DISCLAIMER =
  "درجة التوافق مؤشر إرشادي مبني على المهارات المسجلة ومستوياتها، وليست احتمال قبول أو ضمان توظيف.";

function normalizedSkillLevels(skills: GradSkill[]): Map<string, number> {
  const levels = new Map<string, number>();
  for (const skill of skills ?? []) {
    if (!skill || typeof skill.skill_id !== "string" || !Number.isFinite(skill.level)) continue;
    const id = skill.skill_id.trim().toUpperCase();
    if (!id) continue;
    const level = Math.floor(Math.min(5, Math.max(0, skill.level)));
    if (level < 1) continue;
    levels.set(id, Math.max(levels.get(id) ?? 0, level));
  }
  return levels;
}

const round = (value: number, digits = 0) => {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
};

function scorePath(definition: PathDefinition, levels: Map<string, number>): CareerPathMatch | null {
  const coreSkills = definition.skills.filter((skill) => skill.role === "CORE");
  const matchedCore = coreSkills.filter((skill) => (levels.get(skill.id) ?? 0) > 0);
  if (matchedCore.length < definition.minimum_core_matches) return null;

  const specializationSignals = definition.required_core_any_skill_ids;
  if (specializationSignals.length > 0 &&
      !specializationSignals.some((id) => (levels.get(id) ?? 0) > 0)) return null;

  const matched = definition.skills.filter((skill) => (levels.get(skill.id) ?? 0) > 0);
  const matchedCoreIds = matched.filter((skill) => skill.role === "CORE").map((skill) => skill.id);
  const matchedSupportingIds = matched.filter((skill) => skill.role === "SUPPORTING").map((skill) => skill.id);
  const missingCoreIds = coreSkills.filter((skill) => (levels.get(skill.id) ?? 0) === 0).map((skill) => skill.id);

  const totalWeight = definition.skills.reduce((sum, skill) => sum + skill.weight, 0);
  const weightedLevel = matched.reduce(
    (sum, skill) => sum + skill.weight * (levels.get(skill.id) ?? 0) / 5,
    0,
  );
  const score = round((weightedLevel / totalWeight) * 100);
  const evidence = matched.map((skill) => {
    const level = levels.get(skill.id) ?? 0;
    return {
      skill_id: skill.id,
      level,
      role: skill.role,
      weight: skill.weight,
      contribution: round((skill.weight * level / 5 / totalWeight) * 100, 2),
    };
  });

  const coreCount = matchedCoreIds.length;
  const supportingCount = matchedSupportingIds.length;
  const evidenceDescription = coreCount + " مهارات أساسية و" + supportingCount + " مهارات مساندة";

  return {
    id: definition.id,
    label: definition.label,
    score,
    matched_skill_ids: matched.map((skill) => skill.id),
    matched_core_skill_ids: matchedCoreIds,
    matched_supporting_skill_ids: matchedSupportingIds,
    specialization_signal_skill_ids: matchedCoreIds.filter((id) => specializationSignals.includes(id)),
    missing_core_skill_ids: missingCoreIds,
    next_skill_ids: missingCoreIds.slice(0, 3),
    core_match_count: coreCount,
    required_core_match_count: definition.minimum_core_matches,
    skill_evidence: evidence,
    explanation_ar: "تم ترشيح هذا المسار بناءً على " + evidenceDescription +
      ". المهارات الأساسية لها وزن أعلى من المهارات المساندة.",
  };
}

/**
 * Returns every path supported by at least two core skills.
 * Score = weighted coverage across the whole path catalogue; each core skill is weighted 3,
 * each supporting skill 1, and skill proficiency is normalized to the 1..5 scale.
 */
export function deriveCareerProfile(skills: GradSkill[]): CareerProfile {
  const levels = normalizedSkillLevels(skills);
  const matches = PATHS
    .map((definition) => scorePath(definition, levels))
    .filter((match): match is CareerPathMatch => match !== null);

  matches.sort((a, b) =>
    b.score - a.score ||
    b.core_match_count - a.core_match_count ||
    b.matched_skill_ids.length - a.matched_skill_ids.length ||
    a.id.localeCompare(b.id)
  );

  return {
    primary_path: matches[0] ?? null,
    paths: matches,
    disclaimer: DISCLAIMER,
  };
}
