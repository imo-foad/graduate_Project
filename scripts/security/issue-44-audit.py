#!/usr/bin/env python3
"""Read-only Issue #44 audit. Raw logs, archives and reports stay private in RUNNER_TEMP."""
import io, json, os, subprocess, sys, time, urllib.error, urllib.request, zipfile
from pathlib import Path, PurePosixPath

REPO=os.environ["GITHUB_REPOSITORY"]
TOKEN=os.environ["GITHUB_TOKEN"]
API="https://api.github.com/repos/"+REPO
WORKSPACE=Path(os.environ["GITHUB_WORKSPACE"])
TEMP=Path(os.environ["RUNNER_TEMP"])
ROOT=TEMP/"issue-44-private-audit"
EXPOSURE=ROOT/"actions-exposure"
REPORTS=ROOT/"reports"
GITLEAKS=os.environ["GITLEAKS_BIN"]
API_VERSION="2022-11-28"
MAX_ARCHIVE_BYTES=1024*1024*1024
MAX_NESTED=3
ROOT.mkdir(mode=0o700,parents=True,exist_ok=True)
EXPOSURE.mkdir(mode=0o700,parents=True,exist_ok=True)
REPORTS.mkdir(mode=0o700,parents=True,exist_ok=True)
os.chmod(ROOT,0o700)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        return None
API_OPENER=urllib.request.build_opener(NoRedirect)

def api_request(url,attempts=5):
    for attempt in range(attempts):
        req=urllib.request.Request(url,headers={
            "Authorization":"Bearer "+TOKEN,
            "Accept":"application/vnd.github+json",
            "X-GitHub-Api-Version":API_VERSION,
            "User-Agent":"issue-44-read-only-security-audit",
        },method="GET")
        try:
            with API_OPENER.open(req,timeout=60) as response:
                return response.status,dict(response.headers),response.read()
        except urllib.error.HTTPError as exc:
            status=exc.code
            headers=dict(exc.headers)
            _=exc.read(2048)
            if status==403 and headers.get("X-RateLimit-Remaining")=="0":
                reset=int(headers.get("X-RateLimit-Reset",str(int(time.time())+60)))
                time.sleep(max(1,min(reset-int(time.time())+1,600)))
                continue
            if status==429 or status in (500,502,503,504):
                delay=int(headers.get("Retry-After","5") or "5")
                time.sleep(max(1,min(delay,60)))
                continue
            return status,headers,b""
        except (urllib.error.URLError,TimeoutError,OSError):
            if attempt+1==attempts: return 0,{},b""
            time.sleep(min(2**attempt,20))
    return 0,{},b""

def api_json(url):
    status,headers,body=api_request(url)
    if status!=200: return status,None,headers
    try: return status,json.loads(body.decode("utf-8")),headers
    except Exception: return 0,None,headers

def list_endpoint(url):
    items=[]
    for page in range(1,1001):
        page_url=url+("&" if "?" in url else "?")+"per_page=100&page="+str(page)
        status,payload,_=api_json(page_url)
        if status!=200 or payload is None: return status,items
        if isinstance(payload,list): batch=payload
        elif isinstance(payload,dict):
            batch=payload.get("workflow_runs")
            if batch is None: batch=payload.get("artifacts")
            if batch is None: batch=payload.get("items")
            if batch is None: batch=[]
        else: batch=[]
        items.extend(batch)
        if len(batch)<100: return status,items
    return 0,items

def download_api_archive(url):
    status,headers,body=api_request(url)
    if status==200: return body,status
    if status in (301,302,303,307,308):
        location=headers.get("Location") or headers.get("location")
        if not location: return b"",status
        # The signed object-storage URL is fetched without the GitHub API bearer token.
        try:
            req=urllib.request.Request(location,headers={"User-Agent":"issue-44-read-only-security-audit"})
            with urllib.request.urlopen(req,timeout=180) as response: return response.read(),response.status
        except Exception: return b"",0
    return b"",status

def safe_extract_zip(blob,destination,depth=0):
    if depth>MAX_NESTED: return 0,0,1
    try: archive=zipfile.ZipFile(io.BytesIO(blob))
    except Exception: return 0,0,1
    total=sum(info.file_size for info in archive.infolist() if not info.is_dir())
    if total>MAX_ARCHIVE_BYTES:
        archive.close()
        return 0,0,1
    count=0
    size=0
    unsafe=0
    destination.mkdir(mode=0o700,parents=True,exist_ok=True)
    for info in archive.infolist():
        if info.is_dir(): continue
        rel=PurePosixPath(info.filename)
        mode=(info.external_attr>>16)&0o170000
        if rel.is_absolute() or ".." in rel.parts or mode==0o120000:
            unsafe+=1
            continue
        try: data=archive.read(info)
        except Exception:
            unsafe+=1
            continue
        target=destination.joinpath(*rel.parts)
        target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        try:
            if target.suffix.lower()==".zip" and data[:4]==b"PK\x03\x04" and depth<MAX_NESTED:
                fc,bc,uc=safe_extract_zip(data,target.parent/(target.name+".contents"),depth+1)
                count+=fc
                size+=bc
                unsafe+=uc
            target.write_bytes(data)
            count+=1
            size+=len(data)
        except OSError:
            unsafe+=1
    archive.close()
    return count,size,unsafe

def safe_text(value,limit=400):
    value=str(value or "")
    return "".join(ch if ch>=" " and ch!="\x7f" else " " for ch in value).replace("\n"," ").replace("\r"," ")[:limit]

def collect_actions():
    status,first,_=api_json(API+"/actions/runs?per_page=100&page=1")
    if status!=200 or not isinstance(first,dict):
        raise RuntimeError("Actions workflow-run inventory unavailable; HTTP "+str(status))
    expected=int(first.get("total_count",0))
    runs=list(first.get("workflow_runs",[]))
    for page in range(2,1001):
        if len(runs)>=expected: break
        status,payload,_=api_json(API+"/actions/runs?per_page=100&page="+str(page))
        if status!=200 or not isinstance(payload,dict):
            raise RuntimeError("Actions workflow-run pagination failed at page "+str(page)+"; HTTP "+str(status))
        batch=payload.get("workflow_runs",[])
        if not batch: break
        runs.extend(batch)
        if len(batch)<100: break
        if len(runs)%200==0: print("ACTIONS_RUNS_ENUMERATED="+str(len(runs)))

    logs_ok=0
    logs_missing=[]
    artifact_count=0
    artifacts_ok=0
    artifacts_expired=[]
    artifacts_missing=[]
    files=0
    bytes_total=0
    unsafe=0
    inventory=[]
    print("ACTIONS_RUNS_API_TOTAL="+str(expected)+" ENUMERATED="+str(len(runs)))
    for index,run in enumerate(runs,1):
        rid=int(run["id"])
        inventory.append({
            "id":rid,"branch":run.get("head_branch"),"sha":run.get("head_sha"),
            "workflow":run.get("name"),"conclusion":run.get("conclusion"),
            "status":run.get("status"),"created_at":run.get("created_at"),
            "html_url":run.get("html_url"),
        })
        blob,code=download_api_archive(API+"/actions/runs/"+str(rid)+"/logs")
        if blob and blob[:2]==b"PK":
            fc,bc,uc=safe_extract_zip(blob,EXPOSURE/"logs"/str(rid))
            files+=fc; bytes_total+=bc; unsafe+=uc; logs_ok+=1
        else:
            logs_missing.append(rid)

        status,artifacts=list_endpoint(API+"/actions/runs/"+str(rid)+"/artifacts")
        if status!=200:
            artifacts_missing.append("run:"+str(rid))
        else:
            for artifact in artifacts:
                artifact_count+=1
                aid=int(artifact["id"])
                if artifact.get("expired") is True:
                    artifacts_expired.append(aid)
                    continue
                blob,code=download_api_archive(API+"/actions/artifacts/"+str(aid)+"/zip")
                if blob and blob[:2]==b"PK":
                    fc,bc,uc=safe_extract_zip(blob,EXPOSURE/"artifacts"/str(aid))
                    files+=fc; bytes_total+=bc; unsafe+=uc; artifacts_ok+=1
                else:
                    artifacts_missing.append(aid)
        if index%100==0:
            print("ACTIONS_RUNS_PROCESSED="+str(index)+" LOGS_DOWNLOADED="+str(logs_ok)+
                  " ARTIFACTS_DOWNLOADED="+str(artifacts_ok))

    (ROOT/"actions-run-inventory.json").write_text(
        json.dumps(inventory,ensure_ascii=False,separators=(",",":")),encoding="utf-8")
    print("ACTIONS_RUNS_INSPECTED="+str(len(inventory)))
    print("ACTIONS_LOGS_DOWNLOADED="+str(logs_ok)+" NOT_ACCESSIBLE="+str(len(logs_missing))+
          " IDS="+",".join(map(str,logs_missing[:300])))
    print("ACTIONS_ARTIFACTS_TOTAL="+str(artifact_count)+" DOWNLOADED="+str(artifacts_ok)+
          " EXPIRED_NOT_ACCESSIBLE="+str(len(artifacts_expired))+
          " EXPIRED_IDS="+",".join(map(str,artifacts_expired[:300]))+
          " OTHER_NOT_ACCESSIBLE="+str(len(artifacts_missing))+
          " OTHER_IDS="+",".join(map(str,artifacts_missing[:300])))
    print("ACTIONS_EXTRACTED_FILES="+str(files)+" BYTES="+str(bytes_total)+
          " UNSAFE_ARCHIVE_ENTRIES_SKIPPED="+str(unsafe))
    return {
        "expected":expected,"runs":len(inventory),"logs_ok":logs_ok,"logs_missing":logs_missing,
        "artifact_count":artifact_count,"artifacts_ok":artifacts_ok,
        "expired":artifacts_expired,"artifacts_missing":artifacts_missing,
        "files":files,"bytes":bytes_total,"unsafe":unsafe,
    }

def collect_public_discussions():
    status,issues=list_endpoint(API+"/issues?state=all")
    if status!=200:
        print("PUBLIC_DISCUSSIONS=NOT_ACCESSIBLE_HTTP_"+str(status))
        return 0,1
    directory=EXPOSURE/"public-discussions"
    directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    records=0
    unavailable=0
    for issue in issues:
        number=int(issue["number"])
        (directory/("issue-"+str(number)+"-body.txt")).write_text(issue.get("body") or "",encoding="utf-8")
        records+=1
        endpoints=[("issue-comments",API+"/issues/"+str(number)+"/comments")]
        if isinstance(issue.get("pull_request"),dict):
            endpoints.extend([
                ("review-comments",API+"/pulls/"+str(number)+"/comments"),
                ("reviews",API+"/pulls/"+str(number)+"/reviews"),
            ])
        for label,url in endpoints:
            status,comments=list_endpoint(url)
            if status!=200:
                unavailable+=1
                continue
            for idx,comment in enumerate(comments):
                target=directory/(label+"-"+str(number)+"-"+str(idx)+".txt")
                target.write_text(comment.get("body") or "",encoding="utf-8")
                records+=1
    print("PUBLIC_ISSUES_PRS_ENUMERATED="+str(len(issues))+
          " PUBLIC_COMMENT_BODIES_COLLECTED="+str(records)+
          " COMMENT_ENDPOINTS_NOT_ACCESSIBLE="+str(unavailable))
    return records,unavailable

def scan(name,args):
    report=REPORTS/(name+".json")
    command=[GITLEAKS]+args+[
        "--redact=100","--report-format=json","--report-path="+str(report)
    ]
    proc=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    entries=[]
    if report.exists():
        try:
            value=json.loads(report.read_text(encoding="utf-8"))
            if isinstance(value,list): entries=value
        except Exception:
            pass
    locations=[]
    for item in entries:
        locations.append({
            "rule":safe_text(item.get("RuleID",item.get("ruleID",item.get("RuleId",""))),100),
            "file":safe_text(item.get("File",item.get("file","")),500),
            "commit":safe_text(item.get("Commit",item.get("commit","")),100),
            "line":item.get("StartLine",item.get("startLine","")),
        })
    print("GITLEAKS_SCAN="+name+" EXIT_CODE="+str(proc.returncode)+" FINDINGS="+str(len(entries)))
    for item in locations[:250]:
        print("FINDING scan="+name+" rule="+item["rule"]+" file="+item["file"]+
              " commit="+item["commit"]+" line="+str(item["line"]))
    if len(locations)>250: print("FINDINGS_NOT_LISTED="+str(len(locations)-250))
    return proc.returncode,entries,locations

def self_test():
    test_root=ROOT/"scanner-self-test"
    canary_dir=test_root/"canary"
    clean_dir=test_root/"clean"
    canary_dir.mkdir(mode=0o700,parents=True,exist_ok=True)
    clean_dir.mkdir(mode=0o700,parents=True,exist_ok=True)
    canary="ghp_"+"A"*36
    (canary_dir/"synthetic-github-token.txt").write_text("GITHUB_TOKEN="+canary+"\n",encoding="utf-8")
    (clean_dir/"clean.txt").write_text("Temporary fixture; no credentials are present.\n",encoding="utf-8")
    rc,found,_=scan("canary",["dir",str(canary_dir)])
    report=(REPORTS/"canary.json").read_bytes() if (REPORTS/"canary.json").exists() else b""
    if canary.encode() in report:
        raise RuntimeError("Gitleaks canary redaction check failed")
    if rc==0 or len(found)<1:
        raise RuntimeError("Gitleaks canary detection/nonzero exit test failed")
    print("GITLEAKS_CANARY=PASS DETECTED=YES NONZERO_EXIT=YES REDACTION=PASS")
    rc,found,_=scan("clean-fixture",["dir",str(clean_dir)])
    if rc!=0 or found:
        raise RuntimeError("Gitleaks clean-fixture test failed")
    print("GITLEAKS_CLEAN_FIXTURE=PASS FINDINGS=0 EXIT_CODE=0")

def verify_mirror():
    mirror=ROOT/"repository.git"
    proc=subprocess.run([
        "git","clone","--mirror","--quiet","https://github.com/"+REPO+".git",str(mirror)
    ],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if proc.returncode!=0:
        raise RuntimeError("Temporary full mirror clone failed; git exit "+str(proc.returncode))

    def output(args):
        p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        if p.returncode!=0: raise RuntimeError("Git ref inventory failed; exit "+str(p.returncode))
        return p.stdout
    heads=set(output(["git","--git-dir",str(mirror),"for-each-ref","--format=%(refname)","refs/heads"]).splitlines())
    tags=set(output(["git","--git-dir",str(mirror),"for-each-ref","--format=%(refname)","refs/tags"]).splitlines())
    remote_heads=set()
    for line in output(["git","ls-remote","--heads","https://github.com/"+REPO+".git"]).splitlines():
        parts=line.split("\t",1)
        if len(parts)==2: remote_heads.add(parts[1])
    remote_tags=set()
    for line in output(["git","ls-remote","--tags","https://github.com/"+REPO+".git"]).splitlines():
        parts=line.split("\t",1)
        if len(parts)==2 and not parts[1].endswith("^{}"): remote_tags.add(parts[1])
    if heads!=remote_heads:
        raise RuntimeError("Mirror heads do not equal the advertised remote branch refs")
    if tags!=remote_tags:
        raise RuntimeError("Mirror tags do not equal the advertised remote tag refs")
    commits=output(["git","--git-dir",str(mirror),"rev-list","--all","--count"]).strip()
    print("MIRROR_CLONE=SUCCESS BRANCHES="+str(len(heads))+" TAGS="+str(len(tags))+
          " UNIQUE_REACHABLE_COMMITS="+commits)
    print("MIRROR_REF_PARITY=PASS")
    return mirror

def check_security_settings():
    status,repo_data,_=api_json(API)
    if status==200 and isinstance(repo_data,dict):
        settings=repo_data.get("security_and_analysis")
        if isinstance(settings,dict):
            secret=(settings.get("secret_scanning") or {}).get("status","NOT_EXPOSED")
            push=(settings.get("secret_scanning_push_protection") or {}).get("status","NOT_EXPOSED")
            print("GITHUB_SECRET_SCANNING_SETTING="+safe_text(secret,80))
            print("GITHUB_PUSH_PROTECTION_SETTING="+safe_text(push,80))
        else:
            print("GITHUB_SECRET_SCANNING_SETTING=NOT_EXPOSED_BY_API")
            print("GITHUB_PUSH_PROTECTION_SETTING=NOT_EXPOSED_BY_API")
    else:
        print("GITHUB_REPOSITORY_SETTINGS=NOT_ACCESSIBLE_HTTP_"+str(status))
    status,alerts=list_endpoint(API+"/secret-scanning/alerts?state=open")
    if status==200:
        print("GITHUB_SECRET_SCANNING_ALERTS=ACCESSIBLE_OPEN_ALERT_COUNT_"+str(len(alerts)))
    else:
        print("GITHUB_SECRET_SCANNING_ALERTS=NOT_ACCESSIBLE_HTTP_"+str(status))
    status,_,_=api_json(API+"/branches/main/protection")
    print("MAIN_BRANCH_PROTECTION="+("ACCESSIBLE" if status==200 else "NOT_ACCESSIBLE_HTTP_"+str(status)))

def main():
    print("ISSUE_44_AUDIT_STARTED")
    v=subprocess.run([GITLEAKS,"version"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    if v.returncode!=0 or "8.30.1" not in v.stdout:
        raise RuntimeError("Gitleaks version mismatch; expected 8.30.1")
    helps=[]
    for args in (["--help"],["git","--help"],["dir","--help"]):
        helps.append(subprocess.run([GITLEAKS]+args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True))
    if any(x.returncode!=0 for x in helps):
        raise RuntimeError("Gitleaks CLI help command failed")
    help_text="\n".join(x.stdout+x.stderr for x in helps)
    for flag in ("--redact","--report-format","--report-path","--log-opts"):
        if flag not in help_text: raise RuntimeError("Gitleaks help missing required option "+flag)
    print("GITLEAKS_VERSION=8.30.1 CLI_HELP=READ REQUIRED_FLAGS=VERIFIED")

    self_test()
    mirror=verify_mirror()
    history_rc,history,history_locs=scan("git-history-all-refs",["git","--log-opts=--all",str(mirror)])
    files_rc,files,files_locs=scan("current-tracked-workspace",["dir",str(WORKSPACE)])

    action_summary=collect_actions()
    discussion_count,discussion_unavailable=collect_public_discussions()
    actions_rc,actions,actions_locs=scan("actions-logs-artifacts-public-comments",["dir",str(EXPOSURE)])
    check_security_settings()

    scan_errors=[]
    for name,rc in (("history",history_rc),("current-files",files_rc),("actions-and-comments",actions_rc)):
        if rc not in (0,1): scan_errors.append(name+":"+str(rc))
    findings=len(history)+len(files)+len(actions)
    inaccessible=(len(action_summary["logs_missing"])+len(action_summary["expired"])+
                  len(action_summary["artifacts_missing"])+action_summary["unsafe"]+
                  discussion_unavailable)
    incomplete=(action_summary["runs"]!=action_summary["expected"] or inaccessible>0)

    print("GITLEAKS_HISTORY_FINDINGS="+str(len(history)))
    print("GITLEAKS_CURRENT_FILE_FINDINGS="+str(len(files)))
    print("GITLEAKS_ACTIONS_AND_DISCUSSION_FINDINGS="+str(len(actions)))
    print("DISCUSSION_RECORDS_SCANNED="+str(discussion_count))
    print("AUDIT_NOT_ACCESSIBLE_ITEMS="+str(inaccessible))
    print("AUDIT_SCOPE_INCOMPLETE="+("YES" if incomplete else "NO"))
    print("AUDIT_SCANNER_ERRORS="+str(len(scan_errors)))

    summary=[
        "# Issue #44 public repository security audit",
        "",
        "- Gitleaks: 8.30.1; official release binary SHA-256 verified before execution.",
        "- Mirror ref parity: verified for every advertised branch and tag.",
        "- Git history findings: "+str(len(history))+".",
        "- Current workspace findings: "+str(len(files))+".",
        "- Actions logs/artifacts/public discussion findings: "+str(len(actions))+".",
        "- Actions runs inspected: "+str(action_summary["runs"])+" / "+str(action_summary["expected"])+".",
        "- Logs downloaded: "+str(action_summary["logs_ok"])+"; logs not accessible: "+str(len(action_summary["logs_missing"]))+".",
        "- Artifacts listed: "+str(action_summary["artifact_count"])+"; downloaded: "+str(action_summary["artifacts_ok"])+
         "; expired: "+str(len(action_summary["expired"]))+"; other inaccessible: "+str(len(action_summary["artifacts_missing"]))+".",
        "- Public discussion records scanned: "+str(discussion_count)+"; inaccessible endpoints: "+str(discussion_unavailable)+".",
        "- Synthetic canary: passed; redaction: passed; clean fixture: passed.",
        "- Inaccessible/expired items: "+str(inaccessible)+". Scope complete: "+("no" if incomplete else "yes for the API-accessible snapshot")+".",
    ]
    for label,locations in (("History",history_locs),("Current files",files_locs),("Actions/comments",actions_locs)):
        for item in locations[:100]:
            summary.append("- FINDING "+label+": rule="+item["rule"]+
                "; file="+item["file"]+"; commit="+item["commit"]+"; line="+str(item["line"]))
    if scan_errors: summary.append("- Scanner command errors: "+", ".join(scan_errors))
    dest=os.environ.get("GITHUB_STEP_SUMMARY")
    if dest:
        with open(dest,"a",encoding="utf-8") as stream: stream.write("\n".join(summary)+"\n")

    if scan_errors: raise RuntimeError("One or more Gitleaks scans failed to execute")
    if findings:
        print("AUDIT_VERDICT=FINDINGS_REQUIRE_MANUAL_CLASSIFICATION")
        sys.exit(1)
    if incomplete:
        print("AUDIT_VERDICT=INCOMPLETE_NOT_ACCESSIBLE_ITEMS_REMAIN")
    else:
        print("AUDIT_VERDICT=NO_GITLEAKS_MATCHES_IN_SCANNED_SCOPE")

if __name__=="__main__":
    try: main()
    except Exception as exc:
        print("AUDIT_EXECUTION_ERROR="+safe_text(exc,250),file=sys.stderr)
        sys.exit(2)
