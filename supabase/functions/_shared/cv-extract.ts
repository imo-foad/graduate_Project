// Pure CV helpers (P1). Extraction output is untrusted: validate before it becomes a suggestion (BR-015).
export interface SkillDictEntry { id: string; canonical_name: string; aliases: string[] }
export interface SkillSuggestion { skill_id: string; matched_term: string }

const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Arabic diacritics, tatweel and invisible formatting characters are presentation-only: removing them
// for matching never changes persisted user content. Arabic punctuation separates tokens.
const ARABIC_DIACRITICS = /[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]/g;
const INVISIBLE_FORMATTING = /[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g;
const ARABIC_PUNCTUATION = /[\u060C\u061B\u061F]/g;

/**
 * Normalized view of CV text used only for dictionary matching. Original text is preserved for
 * suggestion `raw_text`/`matched_term` context.
 */
export function normalizeCvMatchText(value: string): string {
  if (typeof value !== "string") return "";
  return value
    .normalize("NFKC")
    .replace(/\u0640/g, "")
    .replace(ARABIC_DIACRITICS, "")
    .replace(INVISIBLE_FORMATTING, "")
    .replace(ARABIC_PUNCTUATION, " ")
    .replace(/[\u00A0\t\r\n]+/g, " ")
    .replace(/\s{2,}/g, " ");
}

/**
 * Boundary classes need to know the script of the term's edge. A Latin-script skill written inside an
 * Arabic sentence is a different token from the Arabic word it is attached to: `وSQL` and `بKotlin`
 * are the conjunction/preposition plus the English skill. Restricting a Latin edge to Latin letters and
 * digits keeps that match while still rejecting `SQLite`, `MySQL` and `JavaScript` for `SQL`/`Java`.
 */
const LATIN_LEAD_BLOCKERS = "\\p{Script=Latin}\\p{N}._+#";
const ANY_LEAD_BLOCKERS = "\\p{L}\\p{N}._+#";
// A trailing dot is sentence punctuation ("Microsoft Excel."), not part of an identifier.
const LATIN_TRAIL_BLOCKERS = "\\p{Script=Latin}\\p{N}_+#";
const ANY_TRAIL_BLOCKERS = "\\p{L}\\p{N}_+#";

function isLatinEdge(character: string | undefined): boolean {
  return typeof character === "string" && /\p{Script=Latin}/u.test(character);
}

function firstCodePoint(value: string): string {
  return Array.from(value)[0] ?? "";
}

function lastCodePoint(value: string): string {
  const characters = Array.from(value);
  return characters[characters.length - 1] ?? "";
}

function buildTermMatcher(term: string): RegExp | null {
  const trimmed = term.trim();
  if (!trimmed) return null;
  const leftBlockers = isLatinEdge(firstCodePoint(trimmed)) ? LATIN_LEAD_BLOCKERS : ANY_LEAD_BLOCKERS;
  const rightBlockers = isLatinEdge(lastCodePoint(trimmed)) ? LATIN_TRAIL_BLOCKERS : ANY_TRAIL_BLOCKERS;
  return new RegExp(`(?<![${leftBlockers}])${escapeRegExp(trimmed)}(?![${rightBlockers}])`, "iu");
}

/** Dictionary-based extraction: whole-term matches only ("Java" must not match "JavaScript"). */
export function extractSkillsFromText(text: string, dict: SkillDictEntry[]): SkillSuggestion[] {
  const normalizedText = normalizeCvMatchText(text);
  const found = new Map<string, string>();
  for (const entry of dict) {
    for (const term of [entry.canonical_name, ...entry.aliases]) {
      const normalizedTerm = normalizeCvMatchText(term).trim();
      if (!normalizedTerm) continue;
      // Dot is part of dotted technology identifiers (Node.js, React.js). A short alias
      // such as "JS" must not match the suffix of "Node.js".
      const matcher = buildTermMatcher(normalizedTerm);
      if (matcher && matcher.test(normalizedText) && !found.has(entry.id)) {
        found.set(entry.id, term.trim());
      }
      if (found.has(entry.id)) break;
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
