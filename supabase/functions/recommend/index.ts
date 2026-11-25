// POST /functions/v1/recommend  { "force"?: boolean }
// Verifies the caller's JWT, then computes/caches recommendations for THAT user only.
// The service-role client is used ONLY for the two server-side RPCs; every user-facing read goes through the user client (RLS).
// NOTE: not executed in the authoring workspace (no Deno/Supabase runtime); orchestration is unit-tested in tests/.
import { createClient } from "npm:@supabase/supabase-js@2";
import { hasActiveAccount, isBannedAuthError } from "../_shared/account-status.ts";
import { runRecommend } from "../_shared/recommend-flow.ts";
import { MODEL_VERSION } from "../_shared/scoring.ts";
import { deriveCareerProfile } from "../_shared/career-profile.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

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

  const body = await req.json().catch(() => ({}));
  const { data: ownSkills, error: skillsError } = await userClient.from("graduate_skills").select("skill_id,level");
  if (skillsError) return json({ error: "PROFILE_SKILLS_READ_FAILED" }, 500);
  const careerProfile = deriveCareerProfile(ownSkills ?? []);
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

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
      .select("*, opportunity:opportunities(id,type,title,company_name,location,attendance_mode,status,deadline,start_at,end_at)")
      .order("score", { ascending: false }),
  }, { force: body?.force === true });
  return json({ ...result.body, career_profile: careerProfile }, result.status);
});
