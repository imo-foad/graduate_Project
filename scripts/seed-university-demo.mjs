// Apply the synthetic university cohort to a disposable local Supabase stack only.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { buildSeed } from "./build-seed.mjs";
import { assertLocalDbUrl } from "./assert-local-db.mjs";
import { assertLocalSupabaseApiUrl, provisionUniversityAccounts } from "./provision-university-demo-users.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export function assertLocalUniversitySeedTargets(apiUrl, dbUrl, env = process.env) {
  const apiBase = assertLocalSupabaseApiUrl(apiUrl);
  const dbTarget = assertLocalDbUrl(dbUrl, env);
  if (new URL(dbUrl).port !== "54322") throw new Error("REFUSING non-standard local Supabase DB port");
  return { apiBase, dbTarget };
}

function runPsql(dbUrl, args) {
  const r = spawnSync("psql", [dbUrl, "-X", "-v", "ON_ERROR_STOP=1", ...args], {
    cwd: ROOT, encoding: "utf8", stdio: ["ignore","pipe","pipe"],
  });
  if (r.error) throw new Error(`Unable to execute psql: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`Local university seed failed: ${(r.stderr || r.stdout || "psql failed").slice(-1000)}`);
  return (r.stdout ?? "").trim();
}

const COUNTS_SQL = `
select concat_ws('|',
 (select count(*) from public.human_identities where identity_type='STUDENT' and verification_source='SYNTHETIC_SEED' and institution_ref like 'SYNTH-STU-%'),
 (select count(*) from public.student_academic_records where record_source='SYNTHETIC_SEED'),
 (select count(distinct gpa) from public.student_academic_records where record_source='SYNTHETIC_SEED'),
 (select count(distinct academic_track) from public.student_academic_records where record_source='SYNTHETIC_SEED'),
 (select count(*) from public.human_identities where identity_type='FACULTY' and verification_source='SYNTHETIC_SEED' and institution_ref like 'SYNTH-FAC-%'),
 (select count(*) from public.faculty_academic_records where record_source='SYNTHETIC_SEED'),
 (select count(*) from private.platform_admins a join public.profiles p on p.id=a.user_id join auth.users u on u.id=p.id where a.is_active and p.phone between '+12125550130' and '+12125550139' and u.raw_user_meta_data->>'synthetic_seed'='true'),
 (select count(*) from public.profiles p join public.graduate_profiles gp on gp.profile_id=p.id where p.phone between '+12125550100' and '+12125550139'),
 (select count(*) from public.human_identities h join public.profiles p on p.id=h.profile_id where p.phone between '+12125550100' and '+12125550139' and h.identity_type='GRADUATE'),
 (select count(*) from public.profiles p join public.graduate_profiles gp on gp.profile_id=p.id where p.email in ('graduate.demo@alumni.test','graduate.android@alumni.test','graduate.data@alumni.test','graduate.cyber@alumni.test')),
 (select count(*) from auth.users u join public.profiles p on p.id=u.id
   where u.raw_user_meta_data->>'synthetic_seed'='true'
     and u.phone between '+12125550100' and '+12125550139'
     and p.phone is distinct from private.normalize_auth_phone(u.phone))
);
`;

function assertCounts(actual) {
  const expected = "20|20|20|7|10|10|10|0|0|4|0";
  if (actual !== expected) throw new Error(`University synthetic invariants failed: got ${actual}, expected ${expected}`);
  return actual;
}

export async function runUniversitySeed({ env = process.env, fetchImpl = fetch } = {}) {
  const apiUrl = env.SUPABASE_URL;
  const dbUrl = env.DB_URL ?? env.SUPABASE_DB_URL;
  // The two explicit URLs are checked before fixture SQL generation, API calls or database writes.
  assertLocalUniversitySeedTargets(apiUrl, dbUrl, env);
  if (!env.SUPABASE_SERVICE_ROLE_KEY) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required");
  if (typeof env.DEMO_PASSWORD !== "string" || env.DEMO_PASSWORD.length < 12) throw new Error("Set DEMO_PASSWORD (minimum 12 characters)");

  const fixturePath = join(ROOT, "fixtures", "university-accounts.json");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
  const sql = buildSeed()["04_university_accounts.sql"];
  if (!sql) throw new Error("University SQL fixture was not generated");
  const sqlPath = join(ROOT, "supabase", "seed", "04_university_accounts.sql");
  writeFileSync(sqlPath, sql, { mode: 0o600 });

  const pass1 = await provisionUniversityAccounts({
    supabaseUrl: apiUrl, serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
    password: env.DEMO_PASSWORD, accounts: fixture, fetchImpl,
  });
  const pass2 = await provisionUniversityAccounts({
    supabaseUrl: apiUrl, serviceRoleKey: env.SUPABASE_SERVICE_ROLE_KEY,
    password: env.DEMO_PASSWORD, accounts: fixture, fetchImpl,
  });
  if (pass2.created !== 0 || pass2.reused !== 40) throw new Error("Auth Admin provisioning second pass was not idempotent");

  const apply = () => runPsql(dbUrl, [
    "-q", "-c", "select set_config('app.synthetic_seed_allowed','local-only',false)",
    "-f", sqlPath,
  ]);
  apply();
  const first = assertCounts(runPsql(dbUrl, ["-A","-t","-c",COUNTS_SQL]));
  apply();
  const second = assertCounts(runPsql(dbUrl, ["-A","-t","-c",COUNTS_SQL]));
  if (first !== second) throw new Error("SQL seed is not idempotent");
  return {
    auth: { firstPass: pass1, secondPass: pass2 },
    firstCounts: first,
    secondCounts: second,
    counts: { students:20, faculty:10, admins:10, distinctGpa:20, gpaScale:4.0, tracks:7, graduates:4 },
  };
}

async function main() {
  const result = await runUniversitySeed();
  console.log("PASS: synthetic university seed applied twice to disposable local Supabase");
  console.log(`Auth first pass: created=${result.auth.firstPass.created}, reused=${result.auth.firstPass.reused}; second pass created=${result.auth.secondPass.created}, reused=${result.auth.secondPass.reused}`);
  console.log(`First-pass counts: ${result.firstCounts}`);
  console.log(`Second-pass counts: ${result.secondCounts}`);
  console.log("Counts: 20 students, 10 faculty, 10 local platform admins, 20 distinct GPA values / 4.0 scale / 7 tracks, 4 existing graduates unchanged");
}
if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e.message); process.exit(1); });
