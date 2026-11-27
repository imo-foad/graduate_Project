// Builds idempotent SQL seed files from fixtures/*.json. Usage: node scripts/build-seed.mjs
// Dates in fixtures are day offsets from the moment the seed is loaded, so a reset always yields a fresh,
// identical scenario (expired stays expired, upcoming stays upcoming).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => JSON.parse(readFileSync(join(ROOT, "fixtures", f), "utf8"));

export const q = (v) => (v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`);
const arr = (a) => (a && a.length ? `array[${a.map(q).join(",")}]::text[]` : "'{}'::text[]");
const ts = (days) => (days === null || days === undefined ? "null" : `now() + interval '${days} days'`);
const oppId = (key) => `(select id from public.opportunities where seed_key = ${q(key)})`;
const gradId = (email) => `(select id from public.profiles where email = ${q(email)})`;

// Final product scope (docs/PRODUCT_DECISIONS.md): the catalogue may only ship these three types.
export const ACTIVE_OPPORTUNITY_TYPES = ["JOB", "INTERNSHIP", "TRAINING"];

export const APPROVED_STUDENT_TRACKS = [
  "Software Engineering","Artificial Intelligence","Data Science and Analytics",
  "Cybersecurity","Mobile Development","Networks and Cloud","Information Systems",
];
export const FACULTY_TITLES = [
  "PROFESSOR","ASSOCIATE_PROFESSOR","ASSISTANT_PROFESSOR","LECTURER","ASSISTANT_LECTURER","TEACHING_ASSISTANT",
];

export function validateUniversityFixtures(d) {
  const errors = [];
  if (!d || d.meta?.source_marker !== "SYNTHETIC_SEED") return ["university fixture must use SYNTHETIC_SEED marker"];
  if (d.meta?.gpa_scale !== 4.0) errors.push("GPA scale must be 4.0");
  for (const [key,n] of [["students",20],["faculty",10],["administrators",10]]) {
    if (!Array.isArray(d[key]) || d[key].length !== n) errors.push(`expected exactly ${n} ${key}`);
  }
  if (errors.length) return errors;
  const all=[...d.students.map(x=>({...x,category:"STUDENT"})),...d.faculty.map(x=>({...x,category:"FACULTY"})),...d.administrators.map(x=>({...x,category:"ADMIN"}))];
  const keys=new Set(), phones=new Set(), refs=new Set();
  for (const u of all) {
    if (!u.seed_key || keys.has(u.seed_key)) errors.push(`missing/duplicate seed_key: ${u.seed_key}`);
    keys.add(u.seed_key);
    if (!/synthetic/i.test(u.full_name ?? "")) errors.push(`${u.seed_key}: name must be explicitly synthetic`);
    if (!(typeof u.phone === "string" && u.phone.length === 12 && u.phone.startsWith("+121255501") && Number(u.phone.slice(-2)) >= 0 && Number(u.phone.slice(-2)) <= 39)) errors.push(`${u.seed_key}: phone outside fictional reserved block`);
    if (phones.has(u.phone)) errors.push(`duplicate synthetic phone ${u.phone}`);
    phones.add(u.phone);
    if (["email","national_id","password"].some(k=>Object.hasOwn(u,k))) errors.push(`${u.seed_key}: forbidden email, National ID or password in fixture`);
    if (u.category==="STUDENT" || u.category==="FACULTY") {
      const prefix=u.category==="STUDENT"?"SYNTH-STU-":"SYNTH-FAC-";
      if (u.identity_type!==u.category) errors.push(`${u.seed_key}: invalid identity type`);
      if (typeof u.institution_ref !== "string" || !/^SYNTH-(?:STU|FAC)-[0-9]{4}$/.test(u.institution_ref) || !u.institution_ref.startsWith(prefix) || refs.has(u.institution_ref)) errors.push(`${u.seed_key}: invalid/duplicate institution_ref`);
      refs.add(u.institution_ref);
    } else if (Object.hasOwn(u,"identity_type") || u.admin_role!=="PLATFORM_ADMIN") {
      errors.push(`${u.seed_key}: administrator must be a private platform-admin grant only`);
    }
  }
  const gpas=new Set(), tracks=new Set();
  for (const s of d.students) {
    if (typeof s.gpa!=="number" || !Number.isFinite(s.gpa) || s.gpa<0 || s.gpa>4 || Math.round(s.gpa*100)!==s.gpa*100) errors.push(`${s.seed_key}: GPA must be 0.00..4.00 to two decimals`);
    if (s.gpa_scale!==4.0) errors.push(`${s.seed_key}: GPA scale must be 4.0`);
    gpas.add(s.gpa);
    if (!APPROVED_STUDENT_TRACKS.includes(s.academic_track)) errors.push(`${s.seed_key}: missing/unsupported academic track`);
    tracks.add(s.academic_track);
    if (!s.department || !s.major || !Number.isInteger(s.academic_level) || s.academic_level<1 || s.academic_level>5) errors.push(`${s.seed_key}: department/major/academic_level required`);
  }
  if(gpas.size!==20) errors.push("all 20 student GPAs must be distinct");
  if(tracks.size<5) errors.push("students must cover at least five approved academic tracks");
  for(const f of d.faculty) if(!f.department || !f.specialization || !FACULTY_TITLES.includes(f.academic_title)) errors.push(`${f.seed_key}: invalid faculty department/specialization/title`);
  return errors;
}


export function validateFixtures({ skills, opportunities, demo }) {
  const errors = [];
  const skillIds = new Set(skills.map((s) => s.id));
  if (skillIds.size !== skills.length) errors.push("duplicate skill ids");
  const keys = new Set();
  for (const o of opportunities) {
    if (keys.has(o.seed_key)) errors.push(`duplicate seed_key ${o.seed_key}`);
    keys.add(o.seed_key);
    if (!ACTIVE_OPPORTUNITY_TYPES.includes(o.type)) errors.push(`${o.seed_key}: inactive opportunity type ${o.type}`);
    for (const s of o.skills ?? []) if (!skillIds.has(s.skill_id)) errors.push(`${o.seed_key}: unknown skill ${s.skill_id}`);
    if (o.end_days !== undefined && o.start_days !== undefined && o.end_days < o.start_days) errors.push(`${o.seed_key}: end before start`);
    if (o.deadline_days !== undefined && o.start_days !== undefined && o.deadline_days > (o.end_days ?? o.start_days)) errors.push(`${o.seed_key}: deadline after event`);
  }
  for (const g of demo) {
    for (const s of g.skills) if (!skillIds.has(s.skill_id)) errors.push(`${g.email}: unknown skill ${s.skill_id}`);
    for (const a of g.applications) if (!keys.has(a.job)) errors.push(`${g.email}: unknown job ${a.job}`);
    for (const r of g.registrations) if (!keys.has(r.event)) errors.push(`${g.email}: unknown event ${r.event}`);
  }
  return errors;
}

export function buildSeed() {
  const skills = read("skills.json"), opportunities = read("opportunities.json"), demo = read("demo-profiles.json");
  const university = read("university-accounts.json");
  const errors = [...validateFixtures({ skills, opportunities, demo }), ...validateUniversityFixtures(university)];
  if (errors.length) throw new Error("Invalid fixtures:\n" + errors.join("\n"));

  const s1 = ["-- GENERATED by scripts/build-seed.mjs from fixtures/skills.json. Idempotent.", "begin;"];
  for (const s of skills) {
    s1.push(`insert into public.skills (id, canonical_name, category, aliases) values (${q(s.id)}, ${q(s.name)}, ${q(s.category)}, ${arr(s.aliases)})
  on conflict (id) do update set canonical_name = excluded.canonical_name, category = excluded.category, aliases = excluded.aliases;`);
  }
  s1.push("commit;");

  const s2 = ["-- GENERATED by scripts/build-seed.mjs from fixtures/opportunities.json. Idempotent; all rows are sample data.", "begin;"];
  for (const o of opportunities) {
    s2.push(`insert into public.opportunities (seed_key, type, title, company_name, organizer_name, description, location, attendance_mode, status, deadline, start_at, end_at, registration_opens_at, capacity, waitlist_enabled, target_fields, is_sample, seed_version)
values (${q(o.seed_key)}, ${q(o.type)}, ${q(o.title)}, ${q(o.company_name)}, ${q(o.organizer_name)}, ${q(o.description)}, ${q(o.location)}, ${q(o.attendance_mode)}, ${q(o.status)}, ${ts(o.deadline_days)}, ${ts(o.start_days)}, ${ts(o.end_days)}, ${ts(o.registration_opens_days)}, ${o.capacity ?? "null"}, ${o.waitlist_enabled ? "true" : "false"}, ${arr(o.target_fields)}, true, 'v1')
on conflict (seed_key) do update set type = excluded.type, title = excluded.title, company_name = excluded.company_name, organizer_name = excluded.organizer_name, description = excluded.description, location = excluded.location, attendance_mode = excluded.attendance_mode, status = excluded.status, deadline = excluded.deadline, start_at = excluded.start_at, end_at = excluded.end_at, registration_opens_at = excluded.registration_opens_at, capacity = excluded.capacity, waitlist_enabled = excluded.waitlist_enabled, target_fields = excluded.target_fields, seed_version = excluded.seed_version;`);
    if (o.job) s2.push(`insert into public.job_details (opportunity_id, employment_type, experience_level, minimum_qualification) values (${oppId(o.seed_key)}, ${q(o.job.employment_type)}, ${q(o.job.experience_level)}, ${q(o.job.minimum_qualification)})
on conflict (opportunity_id) do update set employment_type = excluded.employment_type, experience_level = excluded.experience_level, minimum_qualification = excluded.minimum_qualification;`);
    if (o.event) s2.push(`insert into public.event_details (opportunity_id, venue, target_audience, registration_required) values (${oppId(o.seed_key)}, ${q(o.event.venue)}, ${q(o.event.target_audience)}, ${o.event.registration_required ? "true" : "false"})
on conflict (opportunity_id) do update set venue = excluded.venue, target_audience = excluded.target_audience, registration_required = excluded.registration_required;`);
    s2.push(`delete from public.opportunity_skills where opportunity_id = ${oppId(o.seed_key)};`);
    for (const s of o.skills ?? []) s2.push(`insert into public.opportunity_skills (opportunity_id, skill_id, importance, minimum_level, is_required) values (${oppId(o.seed_key)}, ${q(s.skill_id)}, ${s.importance}, ${s.min_level}, ${s.is_required});`);
    s2.push(`delete from public.opportunity_eligibility where opportunity_id = ${oppId(o.seed_key)};`);
    if (o.eligibility) {
      const e = o.eligibility;
      s2.push(`insert into public.opportunity_eligibility (opportunity_id, min_graduation_year, max_graduation_year, allowed_degrees, required_certifications) values (${oppId(o.seed_key)}, ${e.min_graduation_year ?? "null"}, ${e.max_graduation_year ?? "null"}, ${arr(e.allowed_degrees)}, ${arr(e.required_certifications)});`);
    }
  }
  s2.push("commit;");

  // Demo profile data is applied by e-mail, after scripts/provision-demo-users.mjs created the Auth users.
  const s3 = ["-- GENERATED by scripts/build-seed.mjs from fixtures/demo-profiles.json. Run AFTER provisioning demo users. Idempotent.", "begin;"];
  for (const g of demo) {
    const gid = gradId(g.email);
    s3.push(`update public.profiles set full_name = ${q(g.full_name)} where email = ${q(g.email)};`);
    s3.push(`update public.graduate_profiles set college = ${q(g.college)}, department = ${q(g.department)}, major = ${q(g.major)}, graduation_year = ${g.graduation_year}, degree = ${q(g.degree)}, employment_status = ${q(g.employment_status)}, location = ${q(g.location)}, career_interests = ${arr(g.career_interests)}, work_preferences = ${q(JSON.stringify(g.work_preferences))}::jsonb where profile_id = ${gid};`);
    s3.push(`delete from public.graduate_skills where graduate_id = ${gid} and source = 'SEED';`);
    for (const s of g.skills) s3.push(`insert into public.graduate_skills (graduate_id, skill_id, level, source) select ${gid}, ${q(s.skill_id)}, ${s.level}, 'SEED' where ${gid} is not null on conflict (graduate_id, skill_id) do nothing;`);
    s3.push(`delete from public.career_history where graduate_id = ${gid} and source = 'SEED_SAMPLE';`);
    for (const c of g.career_history) s3.push(`insert into public.career_history (graduate_id, company_name, job_title, field, start_date, end_date, is_current, source) select ${gid}, ${q(c.company)}, ${q(c.title)}, ${q(c.field)}, ${q(c.start)}, ${c.end ? q(c.end) : "null"}, ${c.end ? "false" : "true"}, 'SEED_SAMPLE' where ${gid} is not null;`);
    s3.push(`delete from public.applications where graduate_id = ${gid} and status_source = 'SEED_SAMPLE';`);
    for (const a of g.applications) {
      s3.push(`insert into public.applications (opportunity_id, graduate_id, status, status_source, applied_at, note) select ${oppId(a.job)}, ${gid}, ${q(a.status)}, 'SEED_SAMPLE', now() - interval '${a.days_ago} days', 'Sample historical record (not a real hiring decision)' where ${gid} is not null on conflict (graduate_id, opportunity_id) do nothing;`);
      s3.push(`insert into public.application_status_history (application_id, old_status, new_status, source_type) select id, null, status, 'SEED_SAMPLE' from public.applications where graduate_id = ${gid} and opportunity_id = ${oppId(a.job)} and status_source = 'SEED_SAMPLE';`);
    }
    s3.push(`delete from public.event_registrations where graduate_id = ${gid} and source = 'SEED_SAMPLE';`);
    for (const r of g.registrations) s3.push(`insert into public.event_registrations (opportunity_id, graduate_id, status, source, registered_at) select ${oppId(r.event)}, ${gid}, ${q(r.status)}, 'SEED_SAMPLE', now() - interval '${r.days_ago} days' where ${gid} is not null on conflict (graduate_id, opportunity_id) do nothing;`);
  }
  s3.push(`update public.opportunities o set registered_count = (select count(*) from public.event_registrations r where r.opportunity_id = o.id and r.status = 'REGISTERED');`);
  s3.push(`update public.graduate_profiles set recommendations_dirty = true;`);
  s3.push("commit;");


  // Fourth SQL file is local-only and is applied by seed-university-demo.mjs after phone Auth provisioning.
  const s4 = ["-- GENERATED from fixtures/university-accounts.json. Local-only; no secrets.", "begin;",
    "do $guard$ begin if current_setting('app.synthetic_seed_allowed',true) is distinct from 'local-only' then raise exception 'SYNTHETIC_UNIVERSITY_SEED_REQUIRES_LOCAL_GUARD'; end if; end $guard$;"];
  const authCheck = u => `do $auth_check$ begin if not exists (
    select 1 from public.profiles p join auth.users a on a.id=p.id
    where p.phone=${q(u.phone)} and p.email is null
      and private.normalize_auth_phone(a.phone)=${q(u.phone)}
      and a.phone_confirmed_at is not null
      and a.raw_user_meta_data->>'synthetic_seed' = 'true' and a.raw_user_meta_data->>'seed_key' = ${q(u.seed_key)}
  ) then raise exception ${q("SYNTHETIC_PHONE_AUTH_USER_NOT_CONFIRMED: "+u.seed_key)}; end if; end $auth_check$;`;
  const activate = u => `update public.profiles set full_name=${q(u.full_name)}, account_status='ACTIVE',
    phone_verified_at=coalesce(phone_verified_at,(select phone_confirmed_at from auth.users where id=public.profiles.id))
    where phone=${q(u.phone)};`;
  for (const s of university.students) {
    s4.push(authCheck(s),activate(s));
    s4.push(`insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'STUDENT',${q(s.institution_ref)},'VERIFIED','SYNTHETIC_SEED',
      ${q(JSON.stringify({seed_key:s.seed_key,demo_verification:"SIMULATED_LOCAL_ONLY"}))}::jsonb,now()
      from public.profiles p where p.phone=${q(s.phone)}
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();`);
    s4.push(`insert into public.student_academic_records(profile_id,institution_ref,department,major,academic_track,academic_level,gpa,gpa_scale,record_source)
      select p.id,${q(s.institution_ref)},${q(s.department)},${q(s.major)},${q(s.academic_track)},${s.academic_level},${s.gpa.toFixed(2)},4.0,'SYNTHETIC_SEED'
      from public.profiles p where p.phone=${q(s.phone)}
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,major=excluded.major,
      academic_track=excluded.academic_track,academic_level=excluded.academic_level,gpa=excluded.gpa,gpa_scale=4.0,record_source='SYNTHETIC_SEED';`);
  }
  for (const f of university.faculty) {
    s4.push(authCheck(f),activate(f));
    s4.push(`insert into public.human_identities(profile_id,identity_type,institution_ref,status,verification_source,attributes,verified_at)
      select p.id,'FACULTY',${q(f.institution_ref)},'VERIFIED','SYNTHETIC_SEED',
      ${q(JSON.stringify({seed_key:f.seed_key,demo_verification:"SIMULATED_LOCAL_ONLY"}))}::jsonb,now()
      from public.profiles p where p.phone=${q(f.phone)}
      on conflict(profile_id,identity_type,institution_ref) do update set status='VERIFIED',verification_source='SYNTHETIC_SEED',attributes=excluded.attributes,verified_at=now();`);
    s4.push(`insert into public.faculty_academic_records(profile_id,institution_ref,department,specialization,academic_title,record_source)
      select p.id,${q(f.institution_ref)},${q(f.department)},${q(f.specialization)},${q(f.academic_title)},'SYNTHETIC_SEED'
      from public.profiles p where p.phone=${q(f.phone)}
      on conflict(profile_id) do update set institution_ref=excluded.institution_ref,department=excluded.department,
      specialization=excluded.specialization,academic_title=excluded.academic_title,record_source='SYNTHETIC_SEED';`);
  }
  for (const a of university.administrators) {
    s4.push(authCheck(a),activate(a));
    s4.push(`insert into private.platform_admins(user_id,is_active)
      select p.id,true from public.profiles p where p.phone=${q(a.phone)}
      on conflict(user_id) do update set is_active=true;`);
  }
  s4.push(`do $role_guard$ begin
    if exists(select 1 from public.profiles p join public.graduate_profiles gp on gp.profile_id=p.id where p.phone between '+12125550100' and '+12125550139')
      then raise exception 'SYNTHETIC_STUDENT_FACULTY_ADMIN_MUST_NOT_HAVE_GRADUATE_PROFILE'; end if;
    if exists(select 1 from public.human_identities h join public.profiles p on p.id=h.profile_id
      where p.phone between '+12125550100' and '+12125550139' and h.identity_type='GRADUATE')
      then raise exception 'SYNTHETIC_COHORT_MUST_NOT_HAVE_GRADUATE_IDENTITY'; end if;
  end $role_guard$;`);
  s4.push("commit;");

  return { "01_skills.sql": s1.join("\n") + "\n", "02_catalogue.sql": s2.join("\n") + "\n", "03_demo_profiles.sql": s3.join("\n") + "\n", "04_university_accounts.sql": s4.join("\n") + "\n" };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = buildSeed();
  mkdirSync(join(ROOT, "supabase", "seed"), { recursive: true });
  for (const [name, sql] of Object.entries(out)) writeFileSync(join(ROOT, "supabase", "seed", name), sql);
  console.log("Wrote:", Object.keys(out).map((n) => `supabase/seed/${n}`).join(", "));
}
