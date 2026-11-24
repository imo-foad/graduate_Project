// Pure CV helpers (P1). Extraction output is untrusted: validate before it becomes a suggestion (BR-015).
export interface SkillDictEntry { id: string; canonical_name: string; aliases: string[] }
export interface SkillSuggestion { skill_id: string; matched_term: string }

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Dictionary-based extraction: whole-term matches only ("Java" must not match "JavaScript"). */
export function extractSkillsFromText(text: string, dict: SkillDictEntry[]): SkillSuggestion[] {
  const found = new Map<string, string>();
  for (const e of dict) {
    for (const term of [e.canonical_name, ...e.aliases]) {
      if (!term.trim()) continue;
      const re = new RegExp(`(?<![\\p{L}\\p{N}_+#])${esc(term.trim())}(?![\\p{L}\\p{N}_+#])`, "iu");
      if (re.test(text)) { if (!found.has(e.id)) found.set(e.id, term); break; }
    }
  }
  return [...found].map(([skill_id, matched_term]) => ({ skill_id, matched_term }));
}

export interface ValidatedExtraction { skills: { skill_id: string; level?: number }[]; errors: string[] }

/** Validates model/parser JSON: unknown skill IDs and malformed records are rejected, duplicates removed. */
export function validateExtraction(raw: unknown, allowedSkillIds: Set<string>): ValidatedExtraction {
  const errors: string[] = [];
  const skills: { skill_id: string; level?: number }[] = [];
  const seen = new Set<string>();
  const list = (raw as { skills?: unknown } | null)?.skills;
  if (!Array.isArray(list)) return { skills, errors: ["skills must be an array"] };
  list.forEach((item, i) => {
    const r = item as { skill_id?: unknown; level?: unknown } | null;
    if (!r || typeof r.skill_id !== "string") { errors.push(`skills[${i}]: skill_id missing`); return; }
    if (!allowedSkillIds.has(r.skill_id)) { errors.push(`skills[${i}]: unknown skill_id ${r.skill_id}`); return; }
    if (seen.has(r.skill_id)) return;
    let level: number | undefined;
    if (r.level !== undefined) {
      if (typeof r.level !== "number" || !Number.isInteger(r.level) || r.level < 1 || r.level > 5) {
        errors.push(`skills[${i}]: invalid level`); return;
      }
      level = r.level;
    }
    seen.add(r.skill_id);
    skills.push(level === undefined ? { skill_id: r.skill_id } : { skill_id: r.skill_id, level });
  });
  return { skills, errors };
}
