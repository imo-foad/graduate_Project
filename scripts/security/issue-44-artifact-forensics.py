#!/usr/bin/env python3
"""Read-only forensic scan of every retained Actions artifact for Issue #44."""
import io,json,os,re,stat,subprocess,sys,time,urllib.error,urllib.request,zipfile
from pathlib import Path,PurePosixPath
REPO=os.environ["GITHUB_REPOSITORY"]; TOKEN=os.environ["GITHUB_TOKEN"]
TEMP=Path(os.environ["RUNNER_TEMP"]); WORKSPACE=Path(os.environ["GITHUB_WORKSPACE"])
GITLEAKS=os.environ["GITLEAKS_BIN"]; CONFIG=WORKSPACE/"scripts/security/issue-44-gitleaks.toml"
API="https://api.github.com/repos/"+REPO; VERSION="2022-11-28"
MAX_ARCHIVE_BYTES=1024*1024*1024; MAX_NESTED=3
ROOT=TEMP/"issue-44-artifact-forensics"; EXPOSURE=ROOT/"extracted"; REPORTS=ROOT/"reports"
for d in (ROOT,EXPOSURE,REPORTS): d.mkdir(mode=0o700,parents=True,exist_ok=True); os.chmod(d,0o700)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl): return None
OPENER=urllib.request.build_opener(NoRedirect)
def safe_text(v,n=240):
    v=str(v or "")
    for pat in (r"(?:sb_secret_|sb_publishable_)[A-Za-z0-9_-]{12,}",r"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|sbp_[A-Za-z0-9_]{12,})",r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"):
        v=re.sub(pat,"[REDACTED]",v)
    return "".join(c if c>=" " and c!="\x7f" else " " for c in v).replace("\n"," ").replace("\r"," ")[:n]
def api_request(url,attempts=5):
    for attempt in range(attempts):
        req=urllib.request.Request(url,headers={"Authorization":"Bearer "+TOKEN,"Accept":"application/vnd.github+json","X-GitHub-Api-Version":VERSION,"User-Agent":"issue-44-artifact-forensics"},method="GET")
        try:
            with OPENER.open(req,timeout=60) as r:return r.status,dict(r.headers),r.read()
        except urllib.error.HTTPError as e:
            status=e.code;headers=dict(e.headers);_=e.read(2048)
            if status==403 and headers.get("X-RateLimit-Remaining")=="0":
                reset=int(headers.get("X-RateLimit-Reset",str(int(time.time())+60)));time.sleep(max(1,min(reset-int(time.time())+1,600)));continue
            if status==429 or status in (500,502,503,504):
                time.sleep(max(1,min(int(headers.get("Retry-After","5") or "5"),60)));continue
            return status,headers,b""
        except (urllib.error.URLError,TimeoutError,OSError):
            if attempt+1==attempts:return 0,{},b""
            time.sleep(min(2**attempt,20))
    return 0,{},b""
def api_json(url):
    status,headers,body=api_request(url)
    if status!=200:return status,None,headers
    try:return status,json.loads(body.decode("utf-8")),headers
    except Exception:return 0,None,headers
def list_endpoint(url):
    items=[]
    for page in range(1,1001):
        status,payload,_=api_json(url+("&" if "?" in url else "?")+"per_page=100&page="+str(page))
        if status!=200 or payload is None:return status,items
        batch=payload if isinstance(payload,list) else payload.get("workflow_runs",payload.get("artifacts",payload.get("items",[]))) if isinstance(payload,dict) else []
        items.extend(batch)
        if len(batch)<100:return status,items
    return 0,items
def download_archive(url):
    status,headers,body=api_request(url)
    if status==200:return body,status
    if status in (301,302,303,307,308):
        location=headers.get("Location") or headers.get("location")
        if location:
            try:
                with urllib.request.urlopen(urllib.request.Request(location,headers={"User-Agent":"issue-44-artifact-forensics"}),timeout=180) as r:return r.read(),r.status
            except Exception:return b"",0
    return b"",status
def inspect_zip(blob,dest,origin,records,depth=0):
    if depth>MAX_NESTED:records.append({"origin":origin,"entry":"<nested-archive>","reason":"nested-depth-limit"});return 0,0,1
    try:z=zipfile.ZipFile(io.BytesIO(blob))
    except Exception:records.append({"origin":origin,"entry":"<archive>","reason":"invalid-zip"});return 0,0,1
    infos=z.infolist();total=sum(i.file_size for i in infos if not i.is_dir())
    if total>MAX_ARCHIVE_BYTES:z.close();records.append({"origin":origin,"entry":"<archive>","reason":"uncompressed-size-limit"});return 0,0,1
    count=size=unsafe=0;dest.mkdir(mode=0o700,parents=True,exist_ok=True)
    for idx,info in enumerate(infos,1):
        if info.is_dir():continue
        name=info.filename.replace("\\","/");rel=PurePosixPath(name);mode=(info.external_attr>>16)&0o170000
        reason="unsafe-path" if rel.is_absolute() or ".." in rel.parts or (rel.parts and ":" in rel.parts[0]) else "symlink-entry" if mode==stat.S_IFLNK else None
        try:data=z.read(info)
        except Exception:records.append({"origin":origin,"entry":safe_text(info.filename),"reason":"entry-read-error"});unsafe+=1;continue
        if reason:
            records.append({"origin":origin,"entry":safe_text(info.filename),"reason":reason});unsafe+=1
            q=dest/"_unsafe_quarantine";q.mkdir(mode=0o700,parents=True,exist_ok=True)
            (q/("entry-"+str(idx).zfill(5)+".bin")).write_bytes(data);count+=1;size+=len(data);continue
        target=dest.joinpath(*rel.parts);target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        try:
            if target.suffix.lower()==".zip" and data[:4]==b"PK\x03\x04":
                if depth<MAX_NESTED:
                    fc,bc,uc=inspect_zip(data,target.parent/(target.name+".contents"),origin+"!"+safe_text(info.filename,120),records,depth+1);count+=fc;size+=bc;unsafe+=uc
                else:
                    records.append({"origin":origin,"entry":safe_text(info.filename),"reason":"nested-depth-limit"});unsafe+=1
                    q=dest/"_unsafe_quarantine";q.mkdir(mode=0o700,parents=True,exist_ok=True);(q/("nested-"+str(idx).zfill(5)+".zip")).write_bytes(data)
            target.write_bytes(data);count+=1;size+=len(data)
        except OSError:records.append({"origin":origin,"entry":safe_text(info.filename),"reason":"filesystem-write-error"});unsafe+=1
    z.close();return count,size,unsafe
def main():
    if not CONFIG.is_file():raise RuntimeError("Custom Gitleaks configuration missing")
    v=subprocess.run([GITLEAKS,"version"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if v.returncode or "8.30.1" not in v.stdout:raise RuntimeError("Gitleaks version mismatch")
    status,first,_=api_json(API+"/actions/runs?per_page=100&page=1")
    if status!=200 or not isinstance(first,dict):raise RuntimeError("Actions run inventory unavailable")
    expected=int(first.get("total_count",0));runs=list(first.get("workflow_runs",[]))
    for page in range(2,1001):
        if len(runs)>=expected:break
        status,payload,_=api_json(API+"/actions/runs?per_page=100&page="+str(page))
        if status!=200 or not isinstance(payload,dict):raise RuntimeError("Actions run pagination failed")
        batch=payload.get("workflow_runs",[])
        if not batch:break
        runs.extend(batch)
        if len(batch)<100:break
    print("ARTIFACT_FORENSICS_RUNS="+str(len(runs))+"/"+str(expected),flush=True)
    listed=downloaded=files=bytes_total=0;expired=[];unavailable=[];records=[];inventory=[]
    for ix,run in enumerate(runs,1):
        rid=int(run["id"]);status,artifacts=list_endpoint(API+"/actions/runs/"+str(rid)+"/artifacts")
        if status!=200:unavailable.append("run:"+str(rid));continue
        for a in artifacts:
            listed+=1;aid=int(a["id"]);name=safe_text(a.get("name"),120)
            if a.get("expired") is True:expired.append(aid);continue
            blob,code=download_archive(API+"/actions/artifacts/"+str(aid)+"/zip")
            if not blob or blob[:2]!=b"PK":unavailable.append("artifact:"+str(aid)+":http:"+str(code));continue
            before=len(records);fc,bc,uc=inspect_zip(blob,EXPOSURE/str(aid),"run:"+str(rid)+"/artifact:"+str(aid)+"/"+name,records)
            files+=fc;bytes_total+=bc;downloaded+=1;inventory.append({"run_id":rid,"artifact_id":aid,"name":name,"files":fc,"bytes":bc})
            if len(records)>before:print("UNSAFE_ARTIFACT="+str(aid)+" RUN="+str(rid)+" NAME="+name+" ENTRIES="+str(len(records)-before),flush=True)
        if ix%100==0:print("ARTIFACT_FORENSICS_RUNS_PROCESSED="+str(ix)+" ARTIFACTS_DOWNLOADED="+str(downloaded),flush=True)
    (ROOT/"inventory.json").write_text(json.dumps(inventory,separators=(",",":")),encoding="utf-8")
    print("ARTIFACTS_LISTED="+str(listed)+" DOWNLOADED="+str(downloaded)+" EXPIRED="+str(len(expired))+" UNAVAILABLE="+str(len(unavailable)),flush=True)
    print("ARTIFACT_FILES_EXTRACTED_OR_QUARANTINED="+str(files)+" BYTES="+str(bytes_total),flush=True)
    print("UNSAFE_ENTRIES_TOTAL="+str(len(records)),flush=True)
    for x in records:print("UNSAFE_ENTRY origin="+safe_text(x["origin"],220)+" entry="+safe_text(x["entry"],180)+" reason="+x["reason"],flush=True)
    report=REPORTS/"artifacts.json"
    scan=subprocess.run([GITLEAKS,"dir",str(EXPOSURE),"--config="+str(CONFIG),"--redact=100","--report-format=json","--report-path="+str(report)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    findings=[]
    if report.exists():
        try:
            data=json.loads(report.read_text(encoding="utf-8"));findings=data if isinstance(data,list) else []
        except Exception:pass
    print("ARTIFACT_GITLEAKS_EXIT_CODE="+str(scan.returncode)+" FINDINGS="+str(len(findings)),flush=True)
    for x in findings[:250]:print("ARTIFACT_FINDING rule="+safe_text(x.get("RuleID"),100)+" file="+safe_text(x.get("File"),300)+" line="+str(x.get("StartLine","")),flush=True)
    summary=["# Issue #44 — retained Actions artifact forensics","",
      "- Runs enumerated: "+str(len(runs))+" / "+str(expected)+".",
      "- Artifacts listed/downloaded: "+str(listed)+" / "+str(downloaded)+".",
      "- Expired artifacts: "+str(len(expired))+"; other inaccessible: "+str(len(unavailable))+".",
      "- Files extracted or quarantined: "+str(files)+"; uncompressed bytes: "+str(bytes_total)+".",
      "- Unsafe entries: "+str(len(records))+"; readable unsafe-entry bytes were quarantined under generated safe names and scanned.",
      "- Gitleaks findings: "+str(len(findings))+"."]
    for x in records:summary.append("- Unsafe entry: "+safe_text(x["origin"],220)+" :: "+safe_text(x["entry"],180)+" ("+x["reason"]+").")
    for x in findings[:100]:summary.append("- Finding: rule="+safe_text(x.get("RuleID"),100)+"; file="+safe_text(x.get("File"),300)+"; line="+str(x.get("StartLine",""))+".")
    dest=os.environ.get("GITHUB_STEP_SUMMARY")
    if dest:
        with open(dest,"a",encoding="utf-8") as f:f.write("\n".join(summary)+"\n")
    if scan.returncode not in (0,1):raise RuntimeError("Gitleaks artifact scan failed to execute")
    if unavailable or expired or findings:sys.exit(1)
if __name__=="__main__":
    try:main()
    except Exception as exc:print("ARTIFACT_FORENSICS_ERROR="+safe_text(exc),file=sys.stderr);sys.exit(1)
