// Static SQL helpers (no database needed). They inspect text only; they do NOT prove SQL executes.
import { readdirSync, readFileSync } from "node:fs";

export const migrationsDir = new URL("../supabase/migrations/", import.meta.url);
export const migrationFiles = () => readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
export const readMigration = (f: string) => readFileSync(new URL(f, migrationsDir), "utf8");
export const allMigrationsSql = () => migrationFiles().map(readMigration).join("\n");

const FN_RE = /create or replace function\s+public\.(\w+)\s*\(([\s\S]*?)\)\s*returns[\s\S]*?(\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$)([\s\S]*?)\3/gi;

/** Final definition of each function: later migrations override earlier ones (CREATE OR REPLACE semantics). */
export function finalFunctions(sql: string): Map<string, { params: string; body: string; header: string }> {
  const out = new Map();
  for (const m of sql.matchAll(FN_RE)) {
    const header = m[0].slice(0, m[0].indexOf(m[3]));
    out.set(m[1], { params: m[2], body: m[4], header });
  }
  return out;
}

const stripStrings = (s: string) => s.replace(/'(?:[^']|'')*'/g, "''");
const stripComments = (s: string) => s.replace(/--[^\n]*/g, "");

/**
 * PL/pgSQL FOUND is overwritten by every SELECT INTO / PERFORM / UPDATE / INSERT / DELETE / FOR loop.
 * Rule: any statement that reads FOUND must directly follow a `SELECT ... INTO` or `PERFORM`.
 * (Capture it into a variable right away if it is needed later.)
 */
export function foundViolations(body: string): string[] {
  const stmts = stripStrings(stripComments(body)).split(";").map((s) => s.trim());
  const bad: string[] = [];
  stmts.forEach((s, i) => {
    if (!/\bfound\b/i.test(s)) return;
    const prev = i > 0 ? stmts[i - 1] : "";
    const ok = /^select\b[\s\S]*\binto\b/i.test(prev) || /^perform\b/i.test(prev) ||
      /^(?:update|insert|delete)\b[\s\S]*\breturning\b[\s\S]*\binto\b/i.test(prev) ||
      /\bselect\b[\s\S]*\binto\b[^;]*$/i.test(prev) && !/\bend\s+if\b/i.test(prev);
    if (!ok) bad.push(`${s.slice(0, 60).replace(/\s+/g, " ")}  <-- previous statement: ${prev.slice(0, 50).replace(/\s+/g, " ") || "(none)"}`);
  });
  return bad;
}

/** Balanced quotes/parentheses/dollar-quotes: catches truncated or mangled SQL files. */
export function structureErrors(sql: string): string[] {
  const errs: string[] = [];
  const noComments = stripComments(sql);
  const tags = noComments.match(/\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$/g) ?? [];
  const tagCounts = new Map<string, number>();
  for (const tag of tags) tagCounts.set(tag, (tagCounts.get(tag) ?? 0) + 1);
  for (const [tag, count] of tagCounts) if (count % 2) errs.push(`odd number of ${tag}`);
  let depth = 0;
  let inStr = false;
  let dollar = false;
  for (let i = 0; i < noComments.length; i++) {
    const c = noComments[i];
    if (!inStr && c === "$" && noComments[i + 1] === "$") { dollar = !dollar; i++; continue; }
    if (c === "'") { if (inStr && noComments[i + 1] === "'") { i++; continue; } inStr = !inStr; continue; }
    if (inStr) continue;
    if (c === "(") depth++;
    if (c === ")") { depth--; if (depth < 0) { errs.push("unbalanced ')'"); depth = 0; } }
  }
  if (inStr) errs.push("unterminated string");
  if (depth !== 0) errs.push(`unbalanced parentheses (${depth})`);
  return errs;
}
