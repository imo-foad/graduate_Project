// Free, local rule-based CV extraction. No paid parser API or LLM call.
// Output is untrusted suggestion data: the graduate must review every structured item.
import { normalizeCvMatchText } from "./cv-extract.ts";

export interface CvExperienceSuggestion {
  company_name?: string; job_title?: string; field?: string; description?: string;
  start_date?: string; end_date?: string; is_current?: boolean; raw_text: string; confidence: number;
}
export interface CvCredentialSuggestion {
  title: string; issuer?: string; issue_date?: string; duration?: string; reference_url?: string;
  raw_text: string; confidence: number;
}
export interface StructuredCvData {
  experiences: CvExperienceSuggestion[]; certifications: CvCredentialSuggestion[]; courses: CvCredentialSuggestion[];
}

const HEADINGS: Record<string, string[]> = {
  experience: [
    "work experience", "professional experience", "employment history", "experience",
    "work history", "career history", "employment",
    "الخبرة العملية", "الخبرات العملية", "الخبرة", "الخبرات", "خبرة العمل",
    "الخبرة الوظيفية", "الخبرات الوظيفية", "المسار المهني", "المسار الوظيفي", "الخبرات المهنية", "التاريخ الوظيفي",
  ],
  certification: [
    "certifications", "certificates", "licenses", "professional certifications",
    "certifications and licenses", "الشهادات", "الشهادات المهنية", "شهادات", "الشهادات والدورات",
    "الرخص المهنية", "التراخيص المهنية", "اعتمادات مهنية",
  ],
  course: [
    "courses", "courses and training", "courses & training", "training", "professional development",
    "الدورات", "الكورسات", "الدورات التدريبية", "دورات تدريبية", "التدريب",
    "التدريب والتطوير", "برامج التدريب", "التطوير المهني",
  ],
  ignored: [
    "education", "academic background", "projects", "skills", "technical skills", "core skills",
    "المؤهلات التعليمية", "التعليم", "المشاريع", "المؤهلات العلمية",
    "المهارات", "المهارات التقنية", "المهارات الأساسية",
  ],
};

const MONTHS: Record<string, string> = {
  jan: "01", january: "01", feb: "02", february: "02", mar: "03", march: "03", apr: "04", april: "04", may: "05",
  jun: "06", june: "06", jul: "07", july: "07", aug: "08", august: "08", sep: "09", sept: "09", september: "09",
  oct: "10", october: "10", nov: "11", november: "11", dec: "12", december: "12",
  "يناير": "01", "كانون الثاني": "01", "فبراير": "02", "شباط": "02", "مارس": "03",
  "أبريل": "04", "ابريل": "04", "نيسان": "04", "مايو": "05", "أيار": "05",
  "يونيو": "06", "حزيران": "06", "يوليو": "07", "تموز": "07", "أغسطس": "08",
  "اغسطس": "08", "آب": "08", "سبتمبر": "09", "أيلول": "09", "أكتوبر": "10",
  "اكتوبر": "10", "تشرين الأول": "10", "نوفمبر": "11", "تشرين الثاني": "11",
  "ديسمبر": "12", "كانون الأول": "12",
};
const DATE_YEAR = "(?:19|20|١٩|٢٠|۱۹|۲۰)[0-9٠-٩۰-۹]{2}";
const DATE_MONTH_NAME = "(?:[A-Za-z]{3,9}|يناير|كانون\\s+الثاني|فبراير|شباط|مارس|أبريل|ابريل|نيسان|مايو|أيار|يونيو|حزيران|يوليو|تموز|أغسطس|اغسطس|آب|سبتمبر|أيلول|أكتوبر|اكتوبر|تشرين\\s+الأول|نوفمبر|تشرين\\s+الثاني|ديسمبر|كانون\\s+الأول)";
const DATE_TOKEN = "(?:19|20)[0-9٠-٩۰-۹]{2}-(?:1[0-2]|0?[1-9]|[٠-٩۰-۹]{1,2})" +
  "|(?:" + DATE_MONTH_NAME + "\\s+)?" + DATE_YEAR +
  "|(?:1[0-2]|0?[1-9]|[٠-٩۰-۹]{1,2})\\/(?:19|20)[0-9٠-٩۰-۹]{2}";
const DATE_RANGE = new RegExp("(" + DATE_TOKEN + ")\\s*(?:-|–|—|to|until|through|إلى|حتى)\\s*(present|current|now|ongoing|مستمر|حاليا|حاليًا|(" + DATE_TOKEN + "))", "i");
const ROLE = /developer|engineer|analyst|designer|intern|manager|consultant|administrator|specialist|architect|lead|officer|technician|tester|qa|scientist|researcher|coordinator|accountant|teacher|مدير|مهندس|محلل|مصمم|متدرب|مطور|باحث|فني|محاسب|معلم/i;
const DESCRIPTION_START = /^(?:built|build|developed|develop|managed|led|created|designed|worked|supported|prepared|analy[sz]ed|implemented|maintained|delivered|assisted|helped|responsible|responsible for|contributed|delivered|عملت|عمل|طورت|أدرت|قمت|ساهمت)\b/i;
const PLACEHOLDER_CREDENTIAL = /^(?:none|no|n\/?a|nil|nothing|لا يوجد|لا توجد|بدون|لا شيء)[\s.!]*$/i;

const sectionKeys = new Map<string, string>();
for (const [kind, names] of Object.entries(HEADINGS)) {
  for (const name of names) sectionKeys.set(normalizeHeading(name), kind);
}

function normalizeHeading(value: string): string {
  return normalizeCvMatchText(value)
    .toLowerCase()
    .replace(/[:：|()[\]{}\u060C]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
function cleanLine(value: string): string {
  return value.replace(/^[\s•●▪◦*-]+/, "").replace(/\s+/g, " ").trim();
}
function sectionKind(line: string): string | null {
  return sectionKeys.get(normalizeHeading(line)) ?? null;
}
function extractSections(text: string): Record<string, string[]> {
  const out: Record<string, string[]> = { experience: [], certification: [], course: [] };
  let current: string | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = cleanLine(raw);
    if (!line) continue;
    const kind = sectionKind(line);
    if (kind) {
      current = kind === "ignored" ? null : kind;
      continue;
    }
    if (current) out[current].push(line);
  }
  return out;
}
function dateToIso(token: string, end: boolean): string | undefined {
  const value = token.trim().replace(/[٠-٩۰-۹]/g, (digit) => {
    const code = digit.charCodeAt(0);
    return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
  });
  const numeric = value.match(/^(\d{1,2})\/(\d{4})$/);
  if (numeric) {
    const month = numeric[1].padStart(2, "0");
    const last = new Date(Date.UTC(Number(numeric[2]), Number(month), 0)).getUTCDate();
    return numeric[2] + "-" + month + (end ? "-" + String(last).padStart(2, "0") : "-01");
  }
  const yearMonth = value.match(/^(\d{4})-(\d{1,2})$/);
  if (yearMonth && Number(yearMonth[2]) >= 1 && Number(yearMonth[2]) <= 12) {
    const month = yearMonth[2].padStart(2, "0");
    const last = new Date(Date.UTC(Number(yearMonth[1]), Number(month), 0)).getUTCDate();
    return yearMonth[1] + "-" + month + (end ? "-" + String(last).padStart(2, "0") : "-01");
  }
  const named = value.match(/^(.+?)\s+(\d{4})$/);
  if (named && MONTHS[named[1].toLowerCase()]) {
    const month = MONTHS[named[1].toLowerCase()];
    const last = new Date(Date.UTC(Number(named[2]), Number(month), 0)).getUTCDate();
    return named[2] + "-" + month + (end ? "-" + String(last).padStart(2, "0") : "-01");
  }
  const year = value.match(/^(\d{4})$/);
  if (year) return year[1] + (end ? "-12-31" : "-01-01");
  return undefined;
}
function readDateRange(value: string) {
  const match = value.match(DATE_RANGE);
  if (!match) return { is_current: false };
  const current = /^(present|current|now|ongoing|مستمر|حاليا|حاليًا)$/i.test(match[2]);
  const start = dateToIso(match[1], false) ?? ((match[1].match(/(?:19|20)\d{2}/)?.[0] ?? "") + "-01-01");
  return {
    start_date: start || undefined,
    ...(current ? {} : { end_date: dateToIso(match[3] ?? "", true) }),
    is_current: current,
  };
}
function splitHeader(value: string): { company_name?: string; job_title?: string } {
  // Removing a trailing date range leaves its separator behind ("Role | Company |").
  const header = value.replace(/[\s|—–·]+$/g, "").trim();
  const parts = header.split(/\s+(?:\||·|—|–|@|at)\s+/i).map((part) => part.trim()).filter(Boolean);
  if (parts.length >= 2) {
    const index = parts.findIndex((part) => ROLE.test(part));
    if (index >= 0) {
      const company = parts.find((part, i) => i !== index && !ROLE.test(part));
      return { ...(company ? { company_name: company } : {}), job_title: parts[index] };
    }
    // Without a recognized role keyword, the two fields are ambiguous. Do not guess their meaning.
    return {};
  }
  const at = header.match(/^(.+?)\s+(?:at|@)\s+(.+)$/i);
  if (at) return ROLE.test(at[1]) ? { job_title: at[1].trim(), company_name: at[2].trim() } : { company_name: at[1].trim(), job_title: at[2].trim() };
  if (ROLE.test(header)) return { job_title: header.trim() };
  return {};
}
/** Conservative test for a bare "employer name" line (no role keyword, no sentence shape). */
function looksLikeOrganization(value: string): boolean {
  const words = value.split(/\s+/).filter(Boolean);
  if (words.length === 0 || words.length > 6) return false;
  if (value.length > 70 || /[.;:!?]$/.test(value) || /\d/.test(value)) return false;
  if (DESCRIPTION_START.test(value)) return false;
  return /\p{L}/u.test(value);
}
function experienceBlocks(lines: string[]): string[] {
  const blocks: string[] = [];
  let current: string[] = [];
  let hasDate = false;
  for (const line of lines) {
    const hasRange = DATE_RANGE.test(line);
    const header = ROLE.test(line) && (line.includes("|") || line.includes("@") || /\bat\b/i.test(line));
    if ((hasDate && hasRange) || (hasDate && header)) {
      if (current.length) blocks.push(current.join("\n"));
      current = [];
      hasDate = false;
    }
    current.push(line);
    if (hasRange) hasDate = true;
  }
  if (current.length) blocks.push(current.join("\n"));
  return blocks.slice(0, 30);
}
function parseExperience(block: string): CvExperienceSuggestion | null {
  const dates = readDateRange(block);
  const cleanedLines = block.split(/\r?\n/)
    .map((line) => line.replace(DATE_RANGE, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const headerLines = new Set<number>();
  let company: string | undefined;
  let title: string | undefined;
  for (let index = 0; index < Math.min(2, cleanedLines.length); index++) {
    const candidate = cleanedLines[index].replace(/[()[\]]/g, " ").replace(/\s+/g, " ").trim();
    if (!candidate) continue;
    const parsed = splitHeader(candidate);
    if (parsed.job_title && !title) { title = parsed.job_title; headerLines.add(index); }
    if (parsed.company_name && !company) { company = parsed.company_name; headerLines.add(index); }
    if (parsed.company_name || parsed.job_title) continue;
    // Two-line headers put the employer above or below the role without a separator.
    const partner = index === 0 ? cleanedLines[1] : cleanedLines[0];
    if (!company && partner && ROLE.test(partner) && looksLikeOrganization(candidate)) {
      company = candidate;
      headerLines.add(index);
    }
  }
  const description = cleanedLines
    .filter((_, index) => !headerLines.has(index))
    .join(" ")
    .trim()
    .slice(0, 1200) || undefined;
  const confidence = (dates.start_date ? 0.35 : 0) + (company ? 0.25 : 0) + (title ? 0.25 : 0) + (description ? 0.15 : 0);
  if (!company && !title && !dates.start_date) return null;
  return {
    ...(company ? { company_name: company.slice(0, 200) } : {}),
    ...(title ? { job_title: title.slice(0, 200) } : {}),
    ...(description ? { description } : {}),
    ...(dates.start_date ? { start_date: dates.start_date } : {}),
    ...(dates.end_date ? { end_date: dates.end_date } : {}),
    ...(dates.start_date ? { is_current: dates.is_current } : {}),
    raw_text: block.slice(0, 2000),
    confidence: Math.round(confidence * 100) / 100,
  };
}
function parseCredential(line: string): CvCredentialSuggestion | null {
  const raw = line.slice(0, 1500);
  const url = line.match(/https?:\/\/[^\s)]+/i)?.[0];
  const year = line.match(/\b(?:19|20)\d{2}\b/);
  const dateToken = line.match(new RegExp(DATE_TOKEN, "i"));
  const duration = line.match(/\b\d+\s*(?:hours?|hrs?|weeks?|months?|days?)\b/i)?.[0];
  const clean = line
    .replace(/https?:\/\/[^\s)]+/ig, " ")
    .replace(dateToken?.[0] ?? /$^/, " ")
    .replace(/\b(?:19|20)\d{2}\b/g, " ")
    .replace(/\b\d+\s*(?:hours?|hrs?|weeks?|months?|days?)\b/ig, " ")
    .replace(/\s+/g, " ")
    .trim();
  const normalised = clean.replace(/[\s|—–]+$/g, "").trim();
  if (PLACEHOLDER_CREDENTIAL.test(normalised) || !/\p{L}/u.test(normalised)) return null;
  const parts = normalised.split(/\s*(?:\||—|–| at )\s*/i).map((part) => part.trim()).filter(Boolean);
  const title = (parts[0] ?? clean).slice(0, 200);
  if (!title || title.length < 2) return null;
  const confidence = 0.55 + (parts.length > 1 ? 0.2 : 0) + (year ? 0.15 : 0) + (url ? 0.1 : 0);
  return {
    title,
    ...(parts[1] ? { issuer: parts[1].slice(0, 200) } : {}),
    ...((dateToken?.[0] ? dateToIso(dateToken[0], false) : undefined) ?? (year ? year[0] + "-01-01" : undefined)
      ? { issue_date: (dateToken?.[0] ? dateToIso(dateToken[0], false) : undefined) ?? year![0] + "-01-01" }
      : {}),
    ...(duration ? { duration } : {}),
    ...(url ? { reference_url: url.slice(0, 500) } : {}),
    raw_text: raw,
    confidence: Math.min(0.99, Math.round(confidence * 100) / 100),
  };
}
function unique<T extends { raw_text: string }>(items: T[]): T[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    const key = item.raw_text.toLowerCase().replace(/\s+/g, " ").trim();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
export function extractStructuredCvData(text: string): StructuredCvData {
  const sections = extractSections(text);
  return {
    experiences: unique(experienceBlocks(sections.experience).map(parseExperience).filter((x): x is CvExperienceSuggestion => x !== null)).slice(0, 20),
    certifications: unique(sections.certification.map(parseCredential).filter((x): x is CvCredentialSuggestion => x !== null)).slice(0, 30),
    courses: unique(sections.course.map(parseCredential).filter((x): x is CvCredentialSuggestion => x !== null)).slice(0, 30),
  };
}
