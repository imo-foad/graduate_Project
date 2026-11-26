// POST /functions/v1/recommend  { "force"?: boolean }
// Verifies the caller's JWT, then computes/caches recommendations for THAT user only.
// The service-role client is used only for the per-user quota and the two trusted recommendation RPCs;
// every user-facing read goes through the user client (RLS).
// NOTE: not executed in the authoring workspace (no Deno/Supabase runtime); orchestration is unit-tested in tests/.
import { createClient } from "npm:@supabase/supabase-js@2";
import { hasActiveAccount, isBannedAuthError } from "../_shared/account-status.ts";
import { runRecommend } from "../_shared/recommend-flow.ts";
import { MODEL_VERSION } from "../_shared/scoring.ts";
import { deriveCareerProfile } from "../_shared/career-profile.ts";

const json = (body: unknown, status = 200, extraHeaders: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extraHeaders },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    if (isBannedAuthError(authError)) return json({ error: "ACCOUNT_UNAVAILABLE" }, 403);
    return json({ error: "UNAUTHENTICATED" }, 401);
  }
  if (!(await hasActiveAccount(userClient, user.id))) {
    return json({ error: "ACCOUNT_UNAVAILABLE" }, 403);
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body)
      || Object.keys(body).some((key) => key !== "force")
      || (Object.hasOwn(body, "force") && typeof body.force !== "boolean")) {
    return json({ error: "INVALID_REQUEST" }, 400);
  }

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // Apply a general request budget and a stricter budget to forced recomputations.
  // Fail closed if the trusted rate-limit store cannot be reached.
  const consumeQuota = async (action: string) => {
    const { data, error } = await admin.rpc("consume_edge_rate_limit", {
      p_user_id: user.id,
      p_action: action,
    });
    if (error) return { unavailable: true, retryAfter: 0 };
    return { unavailable: false, retryAfter: Math.max(0, Number(data ?? 0)) };
  };
  const generalQuota = await consumeQuota("RECOMMEND");
  if (generalQuota.unavailable) return json({ error: "RATE_LIMIT_UNAVAILABLE" }, 503);
  if (generalQuota.retryAfter > 0) {
    return json(
      { error: "RATE_LIMIT_EXCEEDED", retry_after_seconds: generalQuota.retryAfter },
      429,
      { "Retry-After": String(generalQuota.retryAfter) },
    );
  }
  const force = body.force === true;
  if (force) {
    const forceQuota = await consumeQuota("RECOMMEND_FORCE");
    if (forceQuota.unavailable) return json({ error: "RATE_LIMIT_UNAVAILABLE" }, 503);
    if (forceQuota.retryAfter > 0) {
      return json(
        { error: "RATE_LIMIT_EXCEEDED", retry_after_seconds: forceQuota.retryAfter },
        429,
        { "Retry-After": String(forceQuota.retryAfter) },
      );
    }
  }

  const { data: ownSkills, error: skillsError } = await userClient.from("graduate_skills").select("skill_id,level");
  if (skillsError) return json({ error: "PROFILE_SKILLS_READ_FAILED" }, 500);
  const careerProfile = deriveCareerProfile(ownSkills ?? []);

  const result = await runRecommend({
    async cacheState() {
      const [profileState, recommendationCount, outdatedModels] = await Promise.all([
        userClient.from("graduate_profiles").select("recommendations_dirty").single(),
        userClient.from("recommendations").select("id", { count: "exact", head: true }),
        userClient.from("recommendations").select("id", { count: "exact", head: true })
          .neq("model_version", MODEL_VERSION),
      ]);
      const dirty = outdatedModels.error
        ? null
        : (outdatedModels.count ?? 0) > 0
          ? true
          : profileState.data?.recommendations_dirty ?? null;
      return { dirty, count: recommendationCount.count ?? 0 };
    },
    candidates: () => admin.rpc("get_recommendation_candidates", { p_graduate_id: user.id }),
    save: async (items, profileVersion) => {
      const { error } = await admin.rpc("save_recommendations", {
        p_graduate_id: user.id, p_items: items, p_model_version: MODEL_VERSION, p_profile_version: profileVersion,
      });
      return { error };
    },
    readCached: () => userClient.from("recommendations")
      .select("*, opportunity:opportunities(id,type,title,company_id,company:companies(verification_status),company_name,location,attendance_mode,status,deadline,start_at,end_at,registration_opens_at,capacity,registered_count,waitlist_enabled)")
      .order("score", { ascending: false }),
  }, { force });
  return json({ ...result.body, career_profile: careerProfile }, result.status);
});
