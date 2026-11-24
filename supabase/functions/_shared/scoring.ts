// Deterministic match scoring (BR-016/017/022). Pure TypeScript: no Deno/Node APIs, so it is unit-testable.
// The LLM never produces the score. Weights come from the business doc (6.5) except where marked ASSUMPTION.
export const MODEL_VERSION = "deterministic-v2-free-personalized";

export type Band = "HIGH" | "GOOD" | "MEDIUM" | "LOW";
export interface GradSkill { skill_id: string; level: number }
export interface GraduateInput {
  major?: string | null; department?: string | null; degree?: string | null;
  graduation_year?: number | null; location?: string | null;
  career_interests: string[];
  work_preferences?: { work_mode?: string; preferred_cities?: string[] } | null;
  experience_years: number;
  inferred_career_paths?: string[];
  interaction_signals?: { target_field: string; weight: number }[];
  skills: GradSkill[];
}
export interface OppSkill { skill_id: string; importance: number; min_level: number; is_required: boolean }
export interface OpportunityInput {
  id: string; type: string; title: string; description?: string | null;
  location?: string | null; attendance_mode?: string | null;
  target_fields?: string[]; experience_level?: string | null; target_audience?: string | null;
  minimum_experience_years?: number | null; minimum_experience_required?: boolean;
  skills: OppSkill[]; eligibility_failures: string[];
}
export interface Gap { skill_id: string; reason: "MISSING" | "LEVEL_TOO_LOW"; required_level: number; current_level: number }
export interface ScoredItem {
  opportunity_id: string; score: number; band: Band;
  score_breakdown: Record<string, number | null>;
  reasons: string[]; explanation_ar: string;
  matched_skill_ids: string[]; missing_skill_ids: string[]; gaps: Gap[];
}

type Criterion = "semantic" | "skills" | "major" | "experience" | "interests" | "location"
  | "relevance" | "audience" | "availability" | "gap_fill" | "interaction";
const WEIGHTS: Record<string, Partial<Record<Criterion, number>>> = {
  JOB: { semantic: 30, skills: 30, major: 10, experience: 15, interests: 5, interaction: 5, location: 5 },
  EVENT: { interests: 25, semantic: 20, relevance: 15, audience: 10, location: 10, availability: 10, interaction: 10 },
  TRAINING: { semantic: 25, gap_fill: 35, interests: 10, major: 10, location: 10, interaction: 10 },
  SCHOLARSHIP: { semantic: 20, skills: 15, major: 15, experience: 5, interests: 15, audience: 20, interaction: 10 },
  COMPETITION: { semantic: 20, skills: 25, experience: 10, interests: 15, interaction: 10, relevance: 10, location: 10 },
};
export function weightProfile(type: string): Partial<Record<Criterion, number>> {
  if (type === "JOB" || type === "INTERNSHIP") return WEIGHTS.JOB;
  if (type === "TRAINING") return WEIGHTS.TRAINING;
  if (type === "SCHOLARSHIP") return WEIGHTS.SCHOLARSHIP;
  if (type === "COMPETITION") return WEIGHTS.COMPETITION;
  return WEIGHTS.EVENT;
}
// ASSUMPTION B3: minimum years implied by each experience level.
const LEVEL_YEARS: Record<string, number> = { FRESH_GRADUATE: 0, JUNIOR: 1, MID: 3, SENIOR: 5 };

export function bandOf(score: number): Band {
  return score >= 80 ? "HIGH" : score >= 65 ? "GOOD" : score >= 50 ? "MEDIUM" : "LOW";
}

const norm = (s: string) => s.toLowerCase().trim();
export function tokens(text: string): Set<string> {
  const out = new Set<string>();
  for (const t of text.toLowerCase().split(/[^\p{L}\p{N}]+/u)) if (t.length >= 3) out.add(t);
  return out;
}
const idTokens = (id: string) => id.toLowerCase().replace(/_/g, " ");

// Lexical stand-in for embedding similarity (ASSUMPTION B4): cosine over token sets, scaled so 0.4 => 1.
function semanticProxy(g: GraduateInput, o: OpportunityInput): number | null {
  const gText = [g.major, g.department, ...g.career_interests, ...(g.inferred_career_paths ?? []), ...g.skills.map((s) => idTokens(s.skill_id))]
    .filter(Boolean).join(" ");
  const oText = [o.title, o.description, ...(o.target_fields ?? []), ...o.skills.map((s) => idTokens(s.skill_id))]
    .filter(Boolean).join(" ");
  const a = tokens(gText), b = tokens(oText);
  if (a.size === 0 || b.size === 0) return null;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter++;
  return Math.min(1, inter / Math.sqrt(a.size * b.size) / 0.4);
}

export function skillAnalysis(g: GraduateInput, o: OpportunityInput) {
  const have = new Map(g.skills.map((s) => [s.skill_id, s.level]));
  const matched: string[] = [], missing: string[] = [], gaps: Gap[] = [];
  let num = 0, den = 0;
  for (const s of o.skills) {
    const cur = have.get(s.skill_id) ?? 0;
    den += s.importance;
    num += s.importance * Math.min(1, cur / Math.max(1, s.min_level));
    if (cur >= s.min_level) matched.push(s.skill_id);
    else {
      gaps.push({ skill_id: s.skill_id, reason: cur === 0 ? "MISSING" : "LEVEL_TOO_LOW", required_level: s.min_level, current_level: cur });
      missing.push(s.skill_id);
    }
  }
  return { matched, missing, gaps, coverage: den === 0 ? null : num / den };
}

function matchesAny(needles: string[], hay: string[]): boolean {
  return needles.some((n) => hay.some((h) => norm(h).includes(norm(n)) || norm(n).includes(norm(h))));
}
function majorScore(g: GraduateInput, o: OpportunityInput): number | null {
  const fields = o.target_fields ?? [];
  const own = [g.major, g.department].filter((x): x is string => !!x);
  if (fields.length === 0 || own.length === 0) return null;
  return matchesAny(fields, own) ? 1 : 0;
}
function interestScore(g: GraduateInput, o: OpportunityInput): number | null {
  const interests = [...g.career_interests, ...(g.inferred_career_paths ?? []).map(idTokens)];
  if (interests.length === 0) return null;
  const hay = [...(o.target_fields ?? []), o.title, ...o.skills.map((s) => idTokens(s.skill_id))];
  return matchesAny(interests, hay) ? 1 : 0;
}
function interactionScore(g: GraduateInput, o: OpportunityInput): number | null {
  const signals = g.interaction_signals ?? [];
  const fields = o.target_fields ?? [];
  if (signals.length === 0 || fields.length === 0) return null;
  const matching = signals.filter((signal) => fields.some((field) =>
    norm(field).includes(norm(signal.target_field)) || norm(signal.target_field).includes(norm(field))));
  if (matching.length === 0) return null;
  const total = Math.max(-4, Math.min(4, matching.reduce((sum, signal) => sum + signal.weight, 0)));
  return Math.max(0, Math.min(1, 0.5 + total / 8));
}
function experienceScore(g: GraduateInput, o: OpportunityInput): number | null {
  const configured = o.minimum_experience_years;
  if ((configured === null || configured === undefined) && (!o.experience_level || !(o.experience_level in LEVEL_YEARS))) return null;
  const need = configured !== null && configured !== undefined ? configured : LEVEL_YEARS[o.experience_level!];
  return need === 0 ? 1 : Math.min(1, g.experience_years / need);
}
// ASSUMPTION B5: location heuristics (doc only says "city match and remote/onsite compatibility").
function locationScore(g: GraduateInput, o: OpportunityInput): number | null {
  const prefs = g.work_preferences ?? {};
  const cities = [g.location, ...(prefs.preferred_cities ?? [])].filter((x): x is string => !!x);
  if (cities.length === 0 && !prefs.work_mode) return null;
  if (o.attendance_mode === "ONLINE") return prefs.work_mode === "ONSITE" ? 0.3 : 1;
  if (!o.location) return null;
  if (matchesAny([o.location], cities)) return 1;
  return prefs.work_mode === "REMOTE" ? 0.2 : 0.3;
}
function audienceScore(g: GraduateInput, o: OpportunityInput): number | null {
  if (!o.target_audience) return null;
  const a = norm(o.target_audience);
  const own = [g.major, g.department, g.degree].filter((x): x is string => !!x).map(norm);
  return a.includes("graduate") || a.includes("خريج") || a.includes("all") || own.some((x) => a.includes(x)) ? 1 : 0;
}
function gapFill(sa: ReturnType<typeof skillAnalysis>, o: OpportunityInput): number | null {
  return o.skills.length === 0 ? null : sa.gaps.length / o.skills.length;
}

const BAND_AR: Record<Band, string> = {
  HIGH: "توافق مرتفع", GOOD: "توافق جيد", MEDIUM: "توافق متوسط", LOW: "توافق منخفض",
};

/** Returns null when a hard eligibility requirement fails (BR-017): such items are never recommended. */
export function scoreOpportunity(g: GraduateInput, o: OpportunityInput): ScoredItem | null {
  if (o.eligibility_failures.length > 0) return null;
  if (o.minimum_experience_required && o.minimum_experience_years !== null
      && o.minimum_experience_years !== undefined && g.experience_years < o.minimum_experience_years) return null;
  const sa = skillAnalysis(g, o);
  const values: Partial<Record<Criterion, number | null>> = {
    semantic: semanticProxy(g, o), skills: sa.coverage, major: majorScore(g, o),
    experience: experienceScore(g, o), interests: interestScore(g, o), location: locationScore(g, o),
    audience: audienceScore(g, o), availability: null, gap_fill: gapFill(sa, o), interaction: interactionScore(g, o),
  };
  const rel = [sa.coverage, majorScore(g, o)].filter((x): x is number => x !== null);
  values.relevance = rel.length ? rel.reduce((a, b) => a + b, 0) / rel.length : null;

  // Criteria with no usable input are excluded and the remaining weights renormalised (ASSUMPTION B6).
  let num = 0, den = 0;
  const breakdown: Record<string, number | null> = {};
  for (const [k, w] of Object.entries(weightProfile(o.type)) as [Criterion, number][]) {
    const v = values[k] ?? null;
    breakdown[k] = v === null ? null : Math.round(v * 1000) / 10;
    if (v !== null) { num += w * v; den += w; }
  }
  const score = den === 0 ? 0 : Math.round((num / den) * 10000) / 100;
  const band = bandOf(score);

  const reasons: string[] = [];
  if (o.skills.length > 0) reasons.push(`يتطابق ${sa.matched.length} من ${o.skills.length} من المهارات المطلوبة.`);
  if (sa.missing.length > 0) reasons.push(`مهارات تحتاج إلى تطويرها: ${sa.missing.join("، ")}.`);
  if (breakdown.interests === 100) reasons.push("تتوافق مع اهتماماتك المهنية.");
  if (breakdown.major === 100) reasons.push("تتوافق مع تخصصك.");
  reasons.push("درجة التوافق ترتيب مساعد وليست احتمال قبول أو ضمان توظيف.");
  return {
    opportunity_id: o.id, score, band, score_breakdown: breakdown, reasons,
    explanation_ar: `${BAND_AR[band]} (${score}/100). ${reasons.join(" ")}`,
    matched_skill_ids: sa.matched, missing_skill_ids: sa.missing, gaps: sa.gaps,
  };
}

/** Ranked list, highest first; ties broken by opportunity id for determinism. */
export function rankOpportunities(g: GraduateInput, opps: OpportunityInput[]): ScoredItem[] {
  return opps.map((o) => scoreOpportunity(g, o)).filter((x): x is ScoredItem => x !== null)
    .sort((a, b) => b.score - a.score || a.opportunity_id.localeCompare(b.opportunity_id));
}
