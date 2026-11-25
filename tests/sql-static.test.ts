import { test } from "node:test";
import assert from "node:assert/strict";
import { allMigrationsSql, finalFunctions, foundViolations, migrationFiles, readMigration, structureErrors } from "./sql-lint.ts";

test("REGRESSION: the lint detects the original register_for_event FOUND bug (0004 as first written)", () => {
  const original = finalFunctions(readMigration("0004_functions.sql")).get("register_for_event")!;
  const v = foundViolations(original.body);
  assert.equal(v.length, 1, v.join("\n"));
  assert.match(v[0], /^if found then/);
});

test("final definition of every function has no stale-FOUND reads", () => {
  const fns = finalFunctions(allMigrationsSql());
  assert.ok(fns.size >= 15, `only ${fns.size} functions parsed`);
  for (const [name, f] of fns) assert.deepEqual(foundViolations(f.body), [], name);
});

test("register_for_event final version captures FOUND immediately", () => {
  const f = finalFunctions(allMigrationsSql()).get("register_for_event")!;
  assert.match(f.body, /v_existing\s*:=\s*found/);
  assert.doesNotMatch(f.body, /if\s+found\b/i);
});

test("every migration has balanced quotes, parentheses and dollar-quotes", () => {
  for (const f of migrationFiles()) assert.deepEqual(structureErrors(readMigration(f)), [], f);
});

test("write RPCs run in one transaction scope and lock before check-then-write", () => {
  const fns = finalFunctions(allMigrationsSql());
  for (const n of ["register_for_event", "cancel_event_registration", "apply_for_scholarship", "apply_for_competition"])
    assert.match(fns.get(n)!.body, /from public\.opportunities where id = p_opportunity_id for update/, n);
  assert.match(fns.get("set_current_job")!.body, /for no key update/);
  assert.match(fns.get("save_recommendations")!.body, /pg_advisory_xact_lock/);
  for (const n of ["register_for_event", "apply_for_job", "apply_for_scholarship", "apply_for_competition"])
    assert.match(fns.get(n)!.body, /is_opportunity_open\(/, `${n} must use the shared open-predicate`);
});

test("open-predicate is defined once in SQL and reused by policies and RPCs", () => {
  const sql = allMigrationsSql();
  assert.match(sql, /create or replace function public\.is_opportunity_open\(/);
  const final = finalFunctions(sql);
  for (const n of ["get_recommendation_candidates", "get_skill_gaps"])
    assert.match(final.get(n)!.body, /is_opportunity_open\(/, n);
  for (const n of ["get_my_insights", "get_skill_gaps"])
    assert.match(final.get(n)!.body, /_open_recommendations\(/, n);
});

test("save_recommendations (final): validate -> lock -> version check -> existence -> only then mutate", () => {
  const f = finalFunctions(allMigrationsSql()).get("save_recommendations")!;
  const at = (re: RegExp) => { const m = f.body.search(re); assert.ok(m >= 0, String(re)); return m; };
  const typeCheck = at(/jsonb_typeof\(p_items\) <> 'array'/);
  const elemCheck = at(/invalid item #/);
  const lock = at(/pg_advisory_xact_lock/);
  const rowLock = at(/from public\.graduate_profiles gp\s+where gp\.profile_id = p_graduate_id for update/);
  const stale = at(/'STALE_SNAPSHOT'/);
  const unknown = at(/unknown opportunity at item/);
  const unavailable = at(/'OPPORTUNITY_UNAVAILABLE'/);
  const del = at(/delete from public\.recommendations/);
  const ins = at(/insert into public\.recommendations/);
  const fresh = at(/recommendations_dirty = false/);
  assert.ok(typeCheck < elemCheck && elemCheck < lock && lock < rowLock && rowLock < stale && stale < unknown
    && unknown < unavailable && unavailable < del && del < ins && ins < fresh, "ordering violated");
  assert.match(f.params, /p_profile_version bigint/);
  assert.doesNotMatch(f.body, /\bjoin public\.opportunities\b[^;]*\binsert\b/is);
});
test("old 3-argument save_recommendations is dropped so the version check cannot be bypassed", () => {
  assert.match(allMigrationsSql(), /drop function if exists public\.save_recommendations\(uuid, jsonb, text\)/);
});
test("profile_version is bumped only by real input changes; cache flag updates cannot bump it", () => {
  const touch = finalFunctions(allMigrationsSql()).get("graduate_profile_touch")!;
  assert.match(touch.body, /profile_version := old\.profile_version \+ 1/);
  assert.doesNotMatch(touch.body.split(/elsif/i)[0].replace(/is distinct from[\s\S]*?then/i, ""), /recommendations_dirty\s+is distinct/i);
  const mark = finalFunctions(allMigrationsSql()).get("mark_recommendations_dirty")!;
  assert.match(mark.body, /profile_version = profile_version \+ 1/);
  const cand = finalFunctions(allMigrationsSql()).get("get_recommendation_candidates")!;
  assert.match(cand.body, /'profile_version'/);
});
test("Edge Function: user-facing reads use the user client; service role only for the two RPCs", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../supabase/functions/recommend/index.ts", import.meta.url), "utf8");
  assert.doesNotMatch(src, /admin\.from\(/);
  assert.match(src, /userClient\.from\("recommendations"\)/);
  const adminUses = [...src.matchAll(/admin\.(\w+)\(\s*"(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`).sort();
  assert.deepEqual(adminUses, ["rpc:consume_edge_rate_limit", "rpc:get_recommendation_candidates", "rpc:save_recommendations"]);
});


test("REGRESSION: scalar text values are appended safely to text arrays", () => {
  const fns = finalFunctions(allMigrationsSql());
  const eligibility = fns.get("eligibility_failures")!;
  const insights = fns.get("get_my_insights")!;
  assert.match(eligibility.body, /array_append\(f,\s*'GRADUATION_YEAR_TOO_EARLY'\)/);
  assert.match(eligibility.body, /array_append\(f,\s*'MISSING_CERTIFICATION:'\s*\|\|\s*cert\)/);
  assert.doesNotMatch(eligibility.body, /\bf\s*:=\s*f\s*\|\|/);
  assert.match(insights.body, /array_append\(missing,\s*'college'\)/);
  assert.doesNotMatch(insights.body, /\bmissing\s*:=\s*missing\s*\|\|/);
});


test("saved-opportunity RLS helper is private from its first migration and cleans up legacy public versions", () => {
  const sql = allMigrationsSql();
  const migration9 = readMigration("0009_fix_saved_opportunity_rls_recursion.sql");
  const migration10 = readMigration("0010_hide_saved_item_helper_from_api.sql");
  assert.match(migration9, /create or replace function private\._opportunity_exists_for_saved_item\(/i);
  assert.match(migration9, /security definer[\s\S]*?set search_path\s*=\s*''/i);
  assert.match(migration9, /revoke all on function private\._opportunity_exists_for_saved_item\(uuid\) from public, anon, authenticated/i);
  assert.match(migration9, /grant execute on function private\._opportunity_exists_for_saved_item\(uuid\) to authenticated/i);
  assert.match(migration9, /create policy saved_insert[\s\S]*?private\._opportunity_exists_for_saved_item\(opportunity_id\)/i);
  assert.doesNotMatch(migration9, /create or replace function public\._opportunity_exists_for_saved_item\(/i);
  assert.doesNotMatch(sql, /grant execute on function public\._opportunity_exists_for_saved_item\(/i);
  assert.match(migration10, /drop function if exists public\._opportunity_exists_for_saved_item\(uuid\)/i);
  assert.match(migration10, /create or replace function private\._opportunity_exists_for_saved_item\(/i);
});




test("Edge Functions use trusted per-user rate limits and fail closed", async () => {
  const { readFileSync } = await import("node:fs");
  const recommend = readFileSync(new URL("../supabase/functions/recommend/index.ts", import.meta.url), "utf8");
  const parseCv = readFileSync(new URL("../supabase/functions/parse-cv/index.ts", import.meta.url), "utf8");
  assert.match(recommend, /consume_edge_rate_limit/);
  assert.match(recommend, /RECOMMEND_FORCE/);
  assert.match(recommend, /RATE_LIMIT_UNAVAILABLE/);
  assert.match(recommend, /Retry-After/);
  assert.match(parseCv, /consume_edge_rate_limit/);
  assert.match(parseCv, /CV_PARSE/);
  assert.match(parseCv, /RATE_LIMIT_UNAVAILABLE/);
  assert.match(parseCv, /Retry-After/);
});
