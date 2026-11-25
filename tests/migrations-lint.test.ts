// STATIC checks over the SQL text. These do NOT execute SQL; they guard security invariants from regressions.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const dir = new URL("../supabase/migrations/", import.meta.url);
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const sql = files.map((f) => readFileSync(new URL(f, dir), "utf8")).join("\n");
const tables = [...sql.matchAll(/create table public\.(\w+)/g)].map((m) => m[1]);

test("migrations are ordered and non-empty", () => {
  assert.deepEqual(files, files.slice().sort());
  assert.ok(tables.length >= 20, `found ${tables.length} tables`);
});
test("every public table has RLS enabled", () => {
  for (const t of tables) assert.match(sql, new RegExp(`alter table public\\.${t} enable row level security`), t);
});
test("no table is writable by clients through catalogue/activity tables", () => {
  const readOnly = ["opportunities", "job_details", "event_details", "opportunity_skills", "opportunity_eligibility",
    "applications", "application_status_history", "event_registrations", "recommendations", "cv_suggestions", "skills",
    "scholarship_applications", "scholarship_application_status_history"];
  for (const t of readOnly) {
    assert.doesNotMatch(sql, new RegExp(`create policy \\w+ on public\\.${t} for (insert|update|delete|all)`), `${t} has a write policy`);
    assert.doesNotMatch(sql, new RegExp(`grant[^;]*(insert|update|delete)[^;]*on[^;]*public\\.${t}\\b[^;]*to authenticated`, "i"), `${t} has a write grant`);
  }
});
test("anon role is never granted anything", () => {
  assert.doesNotMatch(sql, /grant [^;]* to [^;]*\banon\b/i);
});
test("every SECURITY DEFINER function pins search_path", () => {
  const defs = sql.split(/create or replace function/i).slice(1).filter((b) => /security definer/i.test(b.split(/\$\$|\$func\$/)[0] + b.slice(0, 600)));
  assert.ok(defs.length >= 8);
  for (const d of defs) assert.match(d.slice(0, 900), /set search_path = ''/, d.slice(0, 60));
});
test("RPCs derive identity from auth.uid(), not from a graduate-id parameter", () => {
  for (const fn of ["apply_for_job", "withdraw_application", "register_for_event", "cancel_event_registration", "set_current_job", "get_my_insights",
    "apply_for_scholarship", "withdraw_scholarship_application"]) {
    const m = sql.match(new RegExp(`function public\\.${fn}\\([^)]*\\)`));
    assert.ok(m, fn);
    assert.doesNotMatch(m![0], /graduate_id|p_graduate/, `${fn} takes a client-supplied graduate id`);
  }
});
test("service-only functions are not granted to authenticated", () => {
  for (const fn of ["get_recommendation_candidates", "save_recommendations", "eligibility_failures"]) {
    assert.match(sql, new RegExp(`grant execute on function[^;]*public\\.${fn}\\([^;]*to service_role`), fn);
    assert.doesNotMatch(sql, new RegExp(`grant execute on function[^;]*public\\.${fn}\\([^;]*to authenticated`), fn);
  }
});
test("CV parse finalization RPC is service-role only", () => {
  assert.ok(sql.includes("revoke all on function public.complete_cv_parse(uuid, uuid, jsonb)"));
  assert.ok(sql.includes("from public, anon, authenticated"));
  assert.ok(sql.includes("grant execute on function public.complete_cv_parse(uuid, uuid, jsonb) to service_role"));
  assert.ok(!sql.includes("grant execute on function public.complete_cv_parse(uuid, uuid, jsonb) to authenticated"));
});
test("private CV bucket and ownership-scoped storage policies exist", () => {
  assert.match(sql, /'cv-documents', 'cv-documents', false/);
  assert.match(sql, /storage\.foldername\(name\)\)\[1\] = \(select auth\.uid\(\)\)::text/);
});
test("business uniqueness constraints are present (BR-007, BR-012, BR-003)", () => {
  assert.match(sql, /unique \(graduate_id, opportunity_id\),? -- BR-007/);
  assert.match(sql, /unique \(graduate_id, opportunity_id\) -- BR-012/);
  assert.match(sql, /profile_id uuid primary key references public\.profiles/);
  assert.match(sql, /create unique index career_history_one_current/);
});
test("no secrets or demo passwords in SQL", () => {
  assert.doesNotMatch(sql, /service_role_key|eyJ[A-Za-z0-9_-]{20,}|password\s*=/i);
});
