// Free, local rule-based CV extraction. No paid parser API or LLM call.
// Output is untrusted suggestion data: the graduate must review every structured item.
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
const HEADINGS: Record<string,string[]> = {
  experience:["work experience","professional experience","employment history","experience","work history","الخبرة العملية","الخبرات العملية","الخبرات"],
  certification:["certifications","certificates","licenses","الشهادات","الشهادات المهنية"],
  course:["courses","courses and training","courses & training","training","professional development","الدورات","الكورسات","الدورات التدريبية"],
  ignored:["education","academic background","المؤهلات التعليمية","التعليم","projects","المشاريع"],
};
const MONTHS: Record<string,string> = {
  jan:"01",january:"01",feb:"02",february:"02",mar:"03",march:"03",apr:"04",april:"04",may:"05",
  jun:"06",june:"06",jul:"07",july:"07",aug:"08",august:"08",sep:"09",sept:"09",september:"09",
  oct:"10",october:"10",nov:"11",november:"11",dec:"12",december:"12",
};
const DATE_TOKEN = "(?:[A-Za-z]{3,9}\\s+)?(?:19|20)\\d{2}|(?:0?[1-9]|1[0-2])\\/(?:19|20)\\d{2}";
const DATE_RANGE = new RegExp("(" + DATE_TOKEN + ")\\s*(?:-|–|—|to|until|through)\\s*(present|current|now|(" + DATE_TOKEN + "))","i");
const ROLE = /developer|engineer|analyst|designer|intern|manager|consultant|administrator|specialist|architect|lead|officer|technician|tester|qa|scientist|researcher|coordinator|مدير|مهندس|محلل|مصمم|متدرب/i;
function cleanLine(s:string):string { return s.replace(/^[\s•●▪◦*-]+/,"").replace(/\s+/g," ").trim(); }
function sectionKind(s:string):string|null {
  const value=s.toLowerCase().replace(/[:：|()]/g,"").trim();
  for (const [kind,names] of Object.entries(HEADINGS)) if (names.includes(value)) return kind;
  return null;
}
function extractSections(text:string):Record<string,string[]> {
  const out:Record<string,string[]>={experience:[],certification:[],course:[]}; let current:string|null=null;
  for (const raw of text.split(/\r?\n/)) {
    const line=cleanLine(raw); if (!line) continue;
    const kind=sectionKind(line);
    if (kind) { current=kind==="ignored"?null:kind; continue; }
    if (current) out[current].push(line);
  }
  return out;
}
function dateToIso(token:string,end:boolean):string|undefined {
  const value=token.trim(), numeric=value.match(/^(\d{1,2})\/(\d{4})$/);
  if(numeric) return numeric[2]+"-"+numeric[1].padStart(2,"0")+(end?"-28":"-01");
  const named=value.match(/^([A-Za-z]{3,9})\s+(\d{4})$/);
  if(named&&MONTHS[named[1].toLowerCase()]) return named[2]+"-"+MONTHS[named[1].toLowerCase()]+(end?"-28":"-01");
  const year=value.match(/^(\d{4})$/);
  if(year) return year[1]+(end?"-12-31":"-01-01");
  return undefined;
}
function readDateRange(s:string) {
  const m=s.match(DATE_RANGE); if(!m) return {is_current:false};
  const current=/^(present|current|now)$/i.test(m[2]);
  return {start_date:dateToIso(m[1],false),...(current?{}:{end_date:dateToIso(m[3]??"",true)}),is_current:current};
}
function splitHeader(s:string):{company_name?:string;job_title?:string} {
  const parts=s.split(/\s+(?:\||·|—|–|@|at)\s+/i).map(x=>x.trim()).filter(Boolean);
  if(parts.length>=2) {
    const idx=parts.findIndex(x=>ROLE.test(x));
    if(idx>=0) { const co=parts.find((x,i)=>i!==idx&&!ROLE.test(x)); return {...(co?{company_name:co}:{}),job_title:parts[idx]}; }
    return {company_name:parts[0],job_title:parts[1]};
  }
  const at=s.match(/^(.+?)\s+(?:at|@)\s+(.+)$/i);
  if(at) return ROLE.test(at[1])?{job_title:at[1].trim(),company_name:at[2].trim()}:{company_name:at[1].trim(),job_title:at[2].trim()};
  if(ROLE.test(s)) return {job_title:s.trim()};
  return {};
}
function experienceBlocks(lines:string[]):string[] {
  const blocks:string[]=[]; let current:string[]=[]; let hasDate=false;
  for(const line of lines) {
    const hasRange=DATE_RANGE.test(line);
    const header=ROLE.test(line)&&(line.includes("|")||line.includes("@")||/\bat\b/i.test(line));
    if((hasDate&&hasRange)||(hasDate&&header)){if(current.length)blocks.push(current.join(" "));current=[];hasDate=false;}
    current.push(line); if(hasRange)hasDate=true;
  }
  if(current.length)blocks.push(current.join(" "));
  return blocks.slice(0,30);
}
function parseExperience(block:string):CvExperienceSuggestion|null {
  const dates=readDateRange(block), clean=block.replace(DATE_RANGE," ").replace(/\s+/g," ").trim();
  const headerLine=clean.split(/[.;]\s+/)[0]??clean, header=splitHeader(headerLine);
  const description=clean.length>headerLine.length?clean.slice(headerLine.length).replace(/^[-|:,\s]+/,"").slice(0,1200):undefined;
  const confidence=(dates.start_date?0.35:0)+(header.company_name?0.25:0)+(header.job_title?0.25:0)+(description?0.15:0);
  if(!header.company_name&&!header.job_title&&!dates.start_date)return null;
  return {...(header.company_name?{company_name:header.company_name.slice(0,200)}:{}),
    ...(header.job_title?{job_title:header.job_title.slice(0,200)}:{}),...(description?{description}:{}),
    ...(dates.start_date?{start_date:dates.start_date}:{}),...(dates.end_date?{end_date:dates.end_date}:{}),
    ...(dates.start_date?{is_current:dates.is_current}:{}),raw_text:block.slice(0,2000),confidence:Math.round(confidence*100)/100};
}
function parseCredential(line:string):CvCredentialSuggestion|null {
  const raw=line.slice(0,1500), url=line.match(/https?:\/\/[^\s)]+/i)?.[0];
  const year=line.match(/\b(?:19|20)\d{2}\b/), duration=line.match(/\b\d+\s*(?:hours?|hrs?|weeks?|months?|days?)\b/i)?.[0];
  const clean=line.replace(/https?:\/\/[^\s)]+/ig," ").replace(/\b(?:19|20)\d{2}\b/g," ")
    .replace(/\b\d+\s*(?:hours?|hrs?|weeks?|months?|days?)\b/ig," ").replace(/\s+/g," ").trim();
  const parts=clean.split(/\s+(?:\||—|–| at )\s+/i).map(x=>x.trim()).filter(Boolean);
  const title=(parts[0]??clean).slice(0,200); if(!title)return null;
  const confidence=0.55+(parts.length>1?0.2:0)+(year?0.15:0)+(url?0.1:0);
  return {title,...(parts[1]?{issuer:parts[1].slice(0,200)}:{}),...(year?{issue_date:year[0]+"-01-01"}:{}),
    ...(duration?{duration}:{}),...(url?{reference_url:url.slice(0,500)}:{}),raw_text:raw,
    confidence:Math.min(0.99,Math.round(confidence*100)/100)};
}
function unique<T extends {raw_text:string}>(items:T[]):T[] {
  const seen=new Set<string>(); return items.filter(item=>{const key=item.raw_text.toLowerCase().replace(/\s+/g," ").trim();if(seen.has(key))return false;seen.add(key);return true;});
}
export function extractStructuredCvData(text:string):StructuredCvData {
  const sections=extractSections(text);
  return {
    experiences:unique(experienceBlocks(sections.experience).map(parseExperience).filter((x):x is CvExperienceSuggestion=>x!==null)).slice(0,20),
    certifications:unique(sections.certification.map(parseCredential).filter((x):x is CvCredentialSuggestion=>x!==null)).slice(0,30),
    courses:unique(sections.course.map(parseCredential).filter((x):x is CvCredentialSuggestion=>x!==null)).slice(0,30),
  };
}
