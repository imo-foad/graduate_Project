import { readFileSync } from "node:fs";
import type { GraduateInput, OpportunityInput } from "../supabase/functions/_shared/scoring.ts";

const load = (f: string) => JSON.parse(readFileSync(new URL(`../fixtures/${f}`, import.meta.url), "utf8"));
export const opportunities = load("opportunities.json");
export const demo = load("demo-profiles.json");
export const skills = load("skills.json");

export function graduate(email: string): GraduateInput {
  const g = demo.find((d: { email: string }) => d.email === email);
  const years = (g.career_history as { start: string; end: string | null }[]).reduce((a, c) =>
    a + ((c.end ? Date.parse(c.end) : Date.parse("2026-11-22")) - Date.parse(c.start)) / (365.25 * 864e5), 0);
  return {
    major: g.major, department: g.department, degree: g.degree, graduation_year: g.graduation_year,
    location: g.location, career_interests: g.career_interests, work_preferences: g.work_preferences,
    experience_years: years, skills: g.skills,
  };
}
// eligibility_failures is computed in SQL in production; tests inject it explicitly.
export function opps(failures: Record<string, string[]> = {}): OpportunityInput[] {
  return opportunities
    .filter((o: { status: string; deadline_days?: number }) => o.status === "ACTIVE" && (o.deadline_days ?? 1) >= 0)
    .map((o: any) => ({
      id: o.seed_key, type: o.type, title: o.title, description: o.description, location: o.location,
      attendance_mode: o.attendance_mode, target_fields: o.target_fields, skills: o.skills,
      experience_level: o.job?.experience_level ?? null, target_audience: o.event?.target_audience ?? null,
      eligibility_failures: failures[o.seed_key] ?? [],
    }));
}
