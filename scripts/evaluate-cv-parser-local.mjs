// Executable local-only CV extraction evaluation.
// Generates PDF and DOCX fixtures, sends them through the real local parse-cv Edge Function,
// and reports per-category field-level precision/recall. No OCR or paid service is used.
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const base = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "");
const anon = process.env.SUPABASE_ANON_KEY ?? "";
const service = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const password = process.env.DEMO_PASSWORD ?? "";
assert.ok(base && anon && service && password, "local Supabase CV evaluation environment is incomplete");
const parsedBase = new URL(base);
assert.ok(parsedBase.protocol === "http:" && ["127.0.0.1","localhost","[::1]"].includes(parsedBase.hostname) && parsedBase.port === "54321",
  "refusing CV evaluation outside the disposable local Supabase API");

const userEmail = "graduate.demo@alumni.test";
const headers = (key, token, more = {}) => ({
  apikey: key,
  ...(token ? { Authorization: "Bearer " + token } : {}),
  ...more,
});
async function responseJson(res) {
  const raw = await res.text();
  let data = null;
  try { data = raw ? JSON.parse(raw) : null; } catch {}
  return { status: res.status, data, raw };
}
async function request(path, init = {}) {
  return responseJson(await fetch(base + path, { ...init, signal: init.signal ?? AbortSignal.timeout(60_000) }));
}
async function login() {
  const r = await request("/auth/v1/token?grant_type=password", {
    method: "POST", headers: headers(anon,null,{"Content-Type":"application/json"}),
    body: JSON.stringify({email:userEmail,password}),
  });
  assert.equal(r.status,200,"CV evaluation login failed: "+r.raw);
  return {token:r.data.access_token,id:r.data.user.id};
}
function pdfEscape(s) {
  return s.replace(/\\/g,"\\\\").replace(/\(/g,"\\(").replace(/\)/g,"\\)");
}
function makePdf(text) {
  const lines=text.replace(/\r\n?/g,"\n").split("\n");
  const commands=lines.map((line,i)=>(i?"T*\n":"")+"("+pdfEscape(line)+") Tj").join("\n");
  const stream=["BT","/F1 11 Tf","13 TL","45 750 Td",commands,"ET"].join("\n");
  const objects=[
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "5 0 obj\n<< /Length "+Buffer.byteLength(stream,"latin1")+" >>\nstream\n"+stream+"\nendstream\nendobj\n",
  ];
  let output="%PDF-1.4\n% Synthetic CV evaluation fixture\n";
  const offsets=[0];
  for(const obj of objects){offsets.push(Buffer.byteLength(output,"latin1"));output+=obj;}
  const xref=Buffer.byteLength(output,"latin1");
  output+="xref\n0 6\n0000000000 65535 f \n";
  for(let i=1;i<offsets.length;i++) output+=offsets[i].toString().padStart(10,"0")+" 00000 n \n";
  output+="trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"+xref+"\n%%EOF\n";
  return Buffer.from(output,"latin1");
}
function crc32(buf) {
  let crc=0xffffffff;
  for(const byte of buf){
    crc^=byte;
    for(let bit=0;bit<8;bit++) crc=(crc>>>1)^((crc&1)?0xedb88320:0);
  }
  return (crc^0xffffffff)>>>0;
}
function makeZip(entries) {
  const local=[],central=[]; let offset=0;
  for(const [name,value] of entries){
    const nameBytes=Buffer.from(name,"utf8"), data=Buffer.from(value,"utf8"), crc=crc32(data);
    const lh=Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50,0);lh.writeUInt16LE(20,4);lh.writeUInt16LE(0,6);
    lh.writeUInt16LE(0,8);lh.writeUInt16LE(0,10);lh.writeUInt16LE(0,12);
    lh.writeUInt32LE(crc,14);lh.writeUInt32LE(data.length,18);lh.writeUInt32LE(data.length,22);
    lh.writeUInt16LE(nameBytes.length,26);lh.writeUInt16LE(0,28);
    local.push(lh,nameBytes,data);
    const ch=Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50,0);ch.writeUInt16LE(20,4);ch.writeUInt16LE(20,6);
    ch.writeUInt16LE(0,8);ch.writeUInt16LE(0,10);ch.writeUInt16LE(0,12);ch.writeUInt16LE(0,14);
    ch.writeUInt32LE(crc,16);ch.writeUInt32LE(data.length,20);ch.writeUInt32LE(data.length,24);
    ch.writeUInt16LE(nameBytes.length,28);ch.writeUInt16LE(0,30);ch.writeUInt16LE(0,32);
    ch.writeUInt16LE(0,34);ch.writeUInt16LE(0,36);ch.writeUInt32LE(0,38);ch.writeUInt32LE(offset,42);
    central.push(ch,nameBytes);
    offset+=lh.length+nameBytes.length+data.length;
  }
  const centralBytes=Buffer.concat(central), centralOffset=offset, localBytes=Buffer.concat(local);
  const eocd=Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50,0);eocd.writeUInt16LE(0,4);eocd.writeUInt16LE(0,6);
  eocd.writeUInt16LE(entries.length,8);eocd.writeUInt16LE(entries.length,10);
  eocd.writeUInt32LE(centralBytes.length,12);eocd.writeUInt32LE(centralOffset,16);eocd.writeUInt16LE(0,20);
  return Buffer.concat([localBytes,centralBytes,eocd]);
}
function xmlEscape(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
function makeDocx(text) {
  const paragraphs=text.split(/\r?\n/).map(line=>"<w:p><w:r><w:t xml:space=\"preserve\">"+xmlEscape(line)+"</w:t></w:r></w:p>").join("");
  const contentTypes='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>';
  const rels='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
  const document='<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'+paragraphs+'<w:sectPr/></w:body></w:document>';
  return makeZip([["[Content_Types].xml",contentTypes],["_rels/.rels",rels],["word/document.xml",document]]);
}

const cases=[
  {
    key:"english-pdf-standard",
    format:"pdf",
    text:[
      "PROFILE","Backend engineer focused on services.",
      "COURSES","Advanced SQL | Coursera | 2024 | 12 hours",
      "CERTIFICATIONS","AWS Certified Cloud Practitioner | Amazon Web Services | 2023",
      "WORK EXPERIENCE","Backend Engineer | Northstar Systems","Jan 2021 - Feb 2023",
      "Built integrations using Python, Docker and PostgreSQL. Kotlin and SQL.",
    ].join("\n"),
    expected:{
      skills:["PYTHON","DOCKER","POSTGRESQL","KOTLIN","SQL","AWS"],
      experiences:[{company_name:"Northstar Systems",job_title:"Backend Engineer",start_date:"2021-01-01",end_date:"2023-02-28",is_current:false}],
      certifications:[{title:"AWS Certified Cloud Practitioner",issuer:"Amazon Web Services",issue_date:"2023-01-01"}],
      courses:[{title:"Advanced SQL",issuer:"Coursera",issue_date:"2024-01-01",duration:"12 hours"}],
    },
  },
  {
    key:"arabic-docx",
    format:"docx",
    text:[
      "السيرة المهنية",
      "الخبرة العملية","مهندس برمجيات | شركة النور","03/2020 - 11/2021","عمل على خدمات داخلية باستخدام Python وSQL وKotlin.",
      "الشهادات","شهادة الأمن السيبراني | أكاديمية التقنية | 2022",
      "الدورات التدريبية","تحليل البيانات | منصة التعلم | 2023 | 6 weeks",
    ].join("\n"),
    expected:{
      skills:["PYTHON","SQL","KOTLIN"],
      experiences:[{company_name:"شركة النور",job_title:"مهندس برمجيات",start_date:"2020-03-01",end_date:"2021-11-30",is_current:false}],
      certifications:[{title:"شهادة الأمن السيبراني",issuer:"أكاديمية التقنية",issue_date:"2022-01-01"}],
      courses:[{title:"تحليل البيانات",issuer:"منصة التعلم",issue_date:"2023-01-01",duration:"6 weeks"}],
    },
  },
  {
    key:"english-pdf-alternate-order",
    format:"pdf",
    text:[
      "LICENSES","Microsoft Power BI Data Analyst | Microsoft | 2024",
      "EMPLOYMENT HISTORY","Data Analyst at Insight Analytics","2021 - 2022","Prepared reports with Power BI, Excel, Tableau and Statistics.",
      "PROFESSIONAL DEVELOPMENT","Data Visualization with Tableau | Tableau | 2023 | 4 weeks",
    ].join("\n"),
    expected:{
      skills:["POWER_BI","EXCEL","TABLEAU","STATISTICS","DATA_VISUALIZATION"],
      experiences:[{company_name:"Insight Analytics",job_title:"Data Analyst",start_date:"2021-01-01",end_date:"2022-12-31",is_current:false}],
      certifications:[{title:"Microsoft Power BI Data Analyst",issuer:"Microsoft",issue_date:"2024-01-01"}],
      courses:[{title:"Data Visualization with Tableau",issuer:"Tableau",issue_date:"2023-01-01",duration:"4 weeks"}],
    },
  },
  {
    key:"pdf-layout-limitation",
    format:"pdf",
    text:[
      "EXPERIENCE","Product Analyst          Bright Analytics","2019 - 2020","Analysed product reports with Excel and SQL.",
      "CERTIFICATIONS","Professional Scrum Master | Scrum.org | 2020",
      "COURSES","Agile Delivery | Open Learning | 2019",
    ].join("\n"),
    expected:{
      skills:["EXCEL","SQL","AGILE"],
      experiences:[{company_name:"Bright Analytics",job_title:"Product Analyst",start_date:"2019-01-01",end_date:"2020-12-31",is_current:false}],
      certifications:[{title:"Professional Scrum Master",issuer:"Scrum.org",issue_date:"2020-01-01"}],
      courses:[{title:"Agile Delivery",issuer:"Open Learning",issue_date:"2019-01-01"}],
    },
  },
];

const norm=(v)=>String(v).trim().replace(/\s+/g," ").toLowerCase();
function fieldsForExperiences(rows) {
  const keys=["company_name","job_title","start_date","end_date","is_current"];
  return rows.flatMap(row=>keys.filter(k=>row[k]!==undefined).map(k=>k+":"+norm(row[k])));
}
function fieldsForCredentials(rows) {
  const keys=["title","issuer","issue_date","duration"];
  return rows.flatMap(row=>keys.filter(k=>row[k]!==undefined).map(k=>k+":"+norm(row[k])));
}
function metric(expected,actual) {
  const e=new Set(expected),a=new Set(actual);
  const tp=[...e].filter(x=>a.has(x)).length;
  const fp=[...a].filter(x=>!e.has(x)).length;
  const fn=[...e].filter(x=>!a.has(x)).length;
  return {true_positive:tp,false_positive:fp,false_negative:fn,precision:tp/(tp+fp||1),recall:tp/(tp+fn||1),expected:e.size,actual:a.size,
    false_positive_fields:[...a].filter(x=>!e.has(x)),missed_fields:[...e].filter(x=>!a.has(x))};
}
async function upload(uid,token,doc) {
  const id=randomUUID(), path=uid+"/cv-eval-"+id+"."+(doc.format==="docx"?"docx":"pdf");
  const bytes=doc.format==="docx"?makeDocx(doc.text):makePdf(doc.text);
  const mime=doc.format==="docx"?"application/vnd.openxmlformats-officedocument.wordprocessingml.document":"application/pdf";
  const up=await request("/storage/v1/object/cv-documents/"+path.split("/").map(encodeURIComponent).join("/"),{
    method:"POST",headers:headers(anon,token,{"Content-Type":mime,"x-upsert":"false"}),body:bytes,
  });
  assert.ok(up.status===200||up.status===201,doc.key+" upload failed: "+up.raw);
  const meta=await request("/rest/v1/cv_documents",{
    method:"POST",headers:headers(anon,token,{"Content-Type":"application/json",Prefer:"return=representation"}),
    body:JSON.stringify({graduate_id:uid,storage_path:path,file_type:doc.format,size_bytes:bytes.length}),
  });
  assert.equal(meta.status,201,doc.key+" metadata failed: "+meta.raw);
  return {id:meta.data[0].id,path,bytes,mime};
}
async function cleanup(token,path,id) {
  if(path) await request("/storage/v1/object/cv-documents",{
    method:"DELETE",headers:headers(service,token,{"Content-Type":"application/json"}),
    body:JSON.stringify({prefixes:[path]}),
  }).catch(()=>{});
  if(id) await request("/rest/v1/cv_documents?id=eq."+id,{method:"DELETE",headers:headers(service,token)}).catch(()=>{});
}

const loginResult=await login();
const records=[];
const cleanupList=[];
try {
  for(const doc of cases) {
    const file=await upload(loginResult.id,loginResult.token,doc);
    cleanupList.push(file);
    const parsed=await request("/functions/v1/parse-cv",{
      method:"POST",headers:headers(anon,loginResult.token,{"Content-Type":"application/json"}),
      body:JSON.stringify({cv_document_id:file.id}),
    });
    assert.equal(parsed.status,200,doc.key+" parse failed: "+parsed.raw);
    const rows=await request("/rest/v1/cv_suggestions?select=kind,payload,status&cv_document_id=eq."+file.id,{
      headers:headers(anon,loginResult.token),
    });
    assert.equal(rows.status,200,doc.key+" suggestion read failed: "+rows.raw);
    const suggestions=rows.data??[];
    const pending=suggestions.every(row=>row.status==="PENDING");
    assert.ok(pending,doc.key+" produced non-pending suggestions");
    const actual={
      skills:suggestions.filter(x=>x.kind==="SKILL").map(x=>x.payload?.skill_id).filter(Boolean),
      experiences:suggestions.filter(x=>x.kind==="EXPERIENCE").map(x=>x.payload??{}),
      certifications:suggestions.filter(x=>x.kind==="CERTIFICATION").map(x=>x.payload??{}),
      courses:suggestions.filter(x=>x.kind==="COURSE").map(x=>x.payload??{}),
    };
    const expected=doc.expected;
    const report={
      key:doc.key,format:doc.format,pending_suggestions:pending,
      metrics:{
        skills:metric(expected.skills,actual.skills),
        experience_fields:metric(fieldsForExperiences(expected.experiences),fieldsForExperiences(actual.experiences)),
        certification_fields:metric(fieldsForCredentials(expected.certifications),fieldsForCredentials(actual.certifications)),
        course_fields:metric(fieldsForCredentials(expected.courses),fieldsForCredentials(actual.courses)),
      },
    };
    records.push(report);
  }
} finally {
  for(const item of cleanupList) await cleanup(loginResult.token,item.path,item.id);
}
const categories=["skills","experience_fields","certification_fields","course_fields"];
const aggregate={};
for(const category of categories) {
  const values=records.map(x=>x.metrics[category]);
  const tp=values.reduce((n,x)=>n+x.true_positive,0), fp=values.reduce((n,x)=>n+x.false_positive,0), fn=values.reduce((n,x)=>n+x.false_negative,0);
  aggregate[category]={true_positive:tp,false_positive:fp,false_negative:fn,precision:tp/(tp+fp||1),recall:tp/(tp+fn||1)};
}
const report={
  evaluation:"synthetic local CV parser field-level benchmark",
  generated_at:new Date().toISOString(),
  formats:{pdf:cases.filter(x=>x.format==="pdf").length,docx:cases.filter(x=>x.format==="docx").length},
  supported_formats:["text-based PDF","DOCX document.xml text"],
  unsupported_formats:["scanned/image-only PDF (OCR intentionally not implemented or invoked)"],
  limitations:["Multi-column flattened text can merge employer and job-title columns; see pdf-layout-limitation case and its field-level false negatives."],
  documents:records,aggregate,
};
mkdirSync(".ci-logs",{recursive:true});
writeFileSync(".ci-logs/cv-parser-evaluation.json",JSON.stringify(report,null,2)+"\n");
console.log("CV PARSER EVALUATION");
console.log(JSON.stringify({formats:report.formats,aggregate,limitations:report.limitations,unsupported_formats:report.unsupported_formats},null,2));
console.log("Full synthetic field-level metrics: .ci-logs/cv-parser-evaluation.json");
const core=aggregate.skills.recall>=0.75&&aggregate.experience_fields.recall>=0.70&&aggregate.certification_fields.recall>=0.75&&aggregate.course_fields.recall>=0.75;
assert.ok(core,"CV parser field recall fell below the declared minimums; inspect .ci-logs/cv-parser-evaluation.json");
