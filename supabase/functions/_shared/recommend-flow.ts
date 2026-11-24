// Orchestration of POST /recommend, with injected dependencies so it can be unit-tested without Deno/Supabase.
// Guarantees: the version returned with the candidates is passed UNCHANGED to the save; a rejected save never
// touches the cache (the SQL function is atomic); retries are bounded.
import { MODEL_VERSION, rankOpportunities } from "./scoring.ts";
import type { GraduateInput, OpportunityInput, ScoredItem } from "./scoring.ts";
import { filterOpenRecommendations } from "./opportunity-state.ts";

export const MAX_ATTEMPTS = 3;
export const RETRYABLE = new Set(["STALE_SNAPSHOT", "OPPORTUNITY_UNAVAILABLE"]);

export interface Candidates {
  profile_version: number;
  profile: Omit<GraduateInput, "skills">;
  skills: GraduateInput["skills"];
  opportunities: OpportunityInput[];
}
export interface FlowDeps {
  cacheState(): Promise<{ dirty: boolean | null; count: number }>;
  candidates(): Promise<{ data?: Candidates; error?: { message: string } }>;
  save(items: ScoredItem[], profileVersion: number): Promise<{ error?: { message: string } | null }>;
  readCached(): Promise<{ data?: { opportunity?: { status?: string | null; deadline?: string | null; end_at?: string | null } | null }[]; error?: unknown }>;
}
export interface FlowResult { status: number; body: Record<string, unknown> }

export async function runRecommend(deps: FlowDeps, opts: { force?: boolean; maxAttempts?: number } = {}): Promise<FlowResult> {
  const maxAttempts = Math.min(Math.max(opts.maxAttempts ?? MAX_ATTEMPTS, 1), MAX_ATTEMPTS); // hard upper bound
  const state = await deps.cacheState();
  const stale = opts.force === true || state.dirty !== false || state.count === 0;
  let source = "cache";
  if (stale) {
    let saved = false;
    for (let attempt = 1; attempt <= maxAttempts && !saved; attempt++) {
      const { data: cand, error } = await deps.candidates();
      if (error || !cand) return { status: 500, body: { error: "CANDIDATES_FAILED" } };
      const ranked = rankOpportunities({ ...cand.profile, skills: cand.skills }, cand.opportunities);
      const { error: saveError } = await deps.save(ranked, cand.profile_version);
      if (!saveError) { saved = true; break; }
      if (!RETRYABLE.has(saveError.message)) return { status: 500, body: { error: "SAVE_FAILED", code: saveError.message } };
    }
    if (!saved) return { status: 409, body: { error: "STALE_SNAPSHOT", retryable: true, attempts: maxAttempts } };
    source = "computed";
  }
  const { data, error } = await deps.readCached();
  if (error) return { status: 500, body: { error: "READ_FAILED" } };
  return {
    status: 200,
    body: {
      source, model_version: MODEL_VERSION, ai_mode: "deterministic",
      disclaimer: "Match Score is not a hiring probability.",
      items: filterOpenRecommendations(data ?? []),
    },
  };
}
