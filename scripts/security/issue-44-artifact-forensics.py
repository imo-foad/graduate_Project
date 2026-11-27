#!/usr/bin/env python3
"""Bounded, read-only forensics for retained GitHub Actions artifact archives.

Unsafe ZIP paths are quarantined under generated names and their bytes are scanned.
Any archive/member that cannot be completely inspected fails closed as INCOMPLETE.
"""
import json, os, re, shutil, stat, subprocess, sys, time
import urllib.error, urllib.request, zipfile
from pathlib import Path, PurePosixPath
from typing import Any

API_VERSION = "2022-11-28"
PAGE_SIZE = 100
MAX_PAGES = 1000
MAX_DOWNLOAD_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_ENTRY_BYTES = 128 * 1024 * 1024
MAX_TOTAL_EXTRACTED_BYTES = 8 * 1024 * 1024 * 1024
MAX_TOTAL_FILES = 150_000
MAX_NESTED_ARCHIVES = 4
CHUNK_SIZE = 1024 * 1024
GITLEAKS_VERSION = "8.30.1"
SECRET_PATTERNS = (
    r"(?:sb_secret_|sb_publishable_)[A-Za-z0-9_-]{12,}",
    r"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|sbp_[A-Za-z0-9_]{12,})",
    r"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b",
)


class ForensicsError(RuntimeError):
    pass


def safe_text(value: Any, limit: int = 300) -> str:
    text = str(value or "")
    for pattern in SECRET_PATTERNS:
        text = re.sub(pattern, "[REDACTED]", text)
    text = "".join(ch if ch >= " " and ch != "\x7f" else " " for ch in text)
    return text.replace("\n", " ").replace("\r", " ")[:limit]


def validate_inventory(items: list[dict[str, Any]], expected: int, id_key: str = "id") -> None:
    if len(items) != expected:
        raise ForensicsError(f"inventory count mismatch: enumerated={len(items)} expected={expected}")
    identifiers = [str(item.get(id_key, "")) for item in items]
    if any(not value for value in identifiers):
        raise ForensicsError(f"inventory contains an item without {id_key}")
    if len(set(identifiers)) != len(identifiers):
        raise ForensicsError(f"inventory contains duplicate {id_key} values")


def validate_gitleaks_result(exit_code: int, report_exists: bool, findings: Any):
    if not report_exists or not isinstance(findings, list):
        raise ForensicsError("Gitleaks report is missing or is not a JSON array")
    if exit_code not in (0, 1):
        raise ForensicsError(f"Gitleaks execution failed with exit code {exit_code}")
    if exit_code == 0 and findings:
        raise ForensicsError("Gitleaks returned success but its report contains findings")
    if exit_code == 1 and not findings:
        raise ForensicsError("Gitleaks reported findings but its report is empty")
    return findings


class ScanState:
    def __init__(self, exposure_root: Path):
        self.exposure_root = exposure_root
        self.quarantined = []
        self.incomplete = []
        self.manifest = {}
        self.total_files = 0
        self.total_bytes = 0

    def record_incomplete(self, origin: str, member: str, reason: str):
        self.incomplete.append({
            "origin": safe_text(origin, 300), "member": safe_text(member, 300), "reason": reason
        })

    def record_quarantined(self, origin: str, member: str, reason: str):
        self.quarantined.append({
            "origin": safe_text(origin, 300), "member": safe_text(member, 300), "reason": reason
        })


def _safe_component(value: str) -> str:
    value = re.sub(r"[\x00-\x1f\x7f]", "_", value).strip().strip(".")
    if not value or value in {".", ".."}:
        value = "_unnamed"
    return value[:120]


def _unsafe_member_reason(info: zipfile.ZipInfo, raw_name: str):
    normalized = raw_name.replace("\\", "/")
    path = PurePosixPath(normalized)
    mode = (info.external_attr >> 16) & 0o170000
    file_type = stat.S_IFMT(mode)
    if "\x00" in raw_name:
        return "nul-byte-path"
    if not normalized or path.is_absolute():
        return "absolute-or-empty-path"
    if ".." in path.parts:
        return "path-traversal"
    if path.parts and ":" in path.parts[0]:
        return "drive-qualified-path"
    if file_type == stat.S_IFLNK:
        return "symlink-entry"
    if file_type not in (0, stat.S_IFREG):
        return "non-regular-entry"
    if not path.parts:
        return "empty-path"
    return None


def _archive_magic(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
    except OSError:
        return False


def inspect_zip(archive_path: Path, destination: Path, origin: str,
                state: ScanState, depth: int = 0) -> None:
    """Extract readable leaves using generated paths and map each back to its source."""
    try:
        archive = zipfile.ZipFile(archive_path)
    except (OSError, zipfile.BadZipFile, ValueError):
        state.record_incomplete(origin, "<archive>", "invalid-or-unreadable-zip")
        return

    with archive:
        try:
            infos = archive.infolist()
            declared_total = sum(item.file_size for item in infos if not item.is_dir())
        except Exception:
            state.record_incomplete(origin, "<archive>", "central-directory-read-error")
            return
        if declared_total > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
            state.record_incomplete(origin, "<archive>", "archive-uncompressed-size-limit")
            return

        for index, info in enumerate(infos, start=1):
            if info.is_dir():
                continue
            raw_name = info.filename
            unsafe_reason = _unsafe_member_reason(info, raw_name)
            if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
                state.record_incomplete(origin, raw_name, "entry-size-limit")
                continue
            if state.total_files + 1 > MAX_TOTAL_FILES:
                state.record_incomplete(origin, raw_name, "global-file-count-limit")
                continue
            if state.total_bytes + info.file_size > MAX_TOTAL_EXTRACTED_BYTES:
                state.record_incomplete(origin, raw_name, "global-uncompressed-byte-limit")
                continue

            rel = PurePosixPath(raw_name.replace("\\", "/"))
            if unsafe_reason:
                target = destination / "_quarantine" / f"entry-{index:06d}.bin"
                state.record_quarantined(origin, raw_name, unsafe_reason)
            else:
                parts = [_safe_component(part) for part in rel.parts]
                target = destination / "entries" / f"{index:06d}" / Path(*parts)

            try:
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                actual_size = 0
                with archive.open(info, "r") as source, target.open("wb") as output:
                    while True:
                        chunk = source.read(CHUNK_SIZE)
                        if not chunk:
                            break
                        actual_size += len(chunk)
                        if actual_size > MAX_ENTRY_BYTES:
                            raise ForensicsError("entry expanded beyond configured limit")
                        output.write(chunk)
                if actual_size != info.file_size:
                    raise ForensicsError("member size differs from central-directory declaration")
            except (OSError, RuntimeError, zipfile.BadZipFile, NotImplementedError, ForensicsError):
                target.unlink(missing_ok=True)
                state.record_incomplete(origin, raw_name, "entry-read-or-write-error")
                continue

            state.total_files += 1
            state.total_bytes += actual_size
            if _archive_magic(target):
                if depth >= MAX_NESTED_ARCHIVES:
                    state.record_incomplete(origin, raw_name, "nested-archive-depth-limit")
                    target.unlink(missing_ok=True)
                    continue
                nested_dest = target.parent / (target.name + ".contents")
                inspect_zip(
                    target, nested_dest,
                    origin + "!/" + safe_text(raw_name, 240),
                    state, depth + 1,
                )
                target.unlink(missing_ok=True)
                continue

            try:
                relative = target.relative_to(state.exposure_root).as_posix()
            except ValueError:
                state.record_incomplete(origin, raw_name, "extraction-outside-scan-root")
                continue
            state.manifest[relative] = {
                "origin": safe_text(origin, 300), "member": safe_text(raw_name, 300)
            }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


API_OPENER = urllib.request.build_opener(NoRedirect)


def api_open(url: str, attempts: int = 5):
    for attempt in range(attempts):
        request = urllib.request.Request(url, headers={
            "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "issue-44-artifact-forensics",
        }, method="GET")
        try:
            response = API_OPENER.open(request, timeout=90)
            return response, response.status, dict(response.headers)
        except urllib.error.HTTPError as error:
            status, headers = error.code, dict(error.headers)
            error.close()
            if status == 403 and headers.get("X-RateLimit-Remaining") == "0":
                reset = int(headers.get("X-RateLimit-Reset", str(int(time.time()) + 60)))
                time.sleep(max(1, min(reset - int(time.time()) + 1, 600)))
                continue
            if status == 429 or status in (500, 502, 503, 504):
                delay = int(headers.get("Retry-After", "5") or "5")
                time.sleep(max(1, min(delay, 60)))
                continue
            return None, status, headers
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt + 1 == attempts:
                return None, 0, {}
            time.sleep(min(2 ** attempt, 20))
    return None, 0, {}


def api_json(url: str):
    response, status, _ = api_open(url)
    if response is None:
        return status, None
    try:
        with response:
            body = response.read(16 * 1024 * 1024 + 1)
        if len(body) > 16 * 1024 * 1024:
            return 0, None
        return status, json.loads(body.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return 0, None


def list_endpoint(url: str, collection_key: str):
    items = []
    expected = None
    for page in range(1, MAX_PAGES + 1):
        page_url = url + ("&" if "?" in url else "?") + f"per_page={PAGE_SIZE}&page={page}"
        status, payload = api_json(page_url)
        if status != 200 or not isinstance(payload, dict):
            raise ForensicsError(
                f"inventory endpoint failed: http={status} collection={collection_key}"
            )
        batch = payload.get(collection_key)
        if not isinstance(batch, list):
            raise ForensicsError(f"inventory response omitted {collection_key}")
        reported_total = payload.get("total_count")
        if not isinstance(reported_total, int) or reported_total < 0:
            raise ForensicsError(f"inventory omitted total_count for {collection_key}")
        if expected is None:
            expected = reported_total
        elif expected != reported_total:
            raise ForensicsError(f"total_count changed during {collection_key} pagination")
        items.extend(batch)
        if len(items) > expected:
            raise ForensicsError(f"{collection_key} inventory exceeded total_count")
        if len(batch) < PAGE_SIZE:
            validate_inventory(items, expected)
            return items, expected
    raise ForensicsError(f"pagination limit reached for {collection_key}")


def download_archive(url: str, destination: Path):
    """Stream an artifact ZIP to private disk with a hard compressed-size limit."""
    response, status, headers = api_open(url)
    if response is None and status in (301, 302, 303, 307, 308):
        location = headers.get("Location") or headers.get("location")
        if location:
            try:
                response = urllib.request.urlopen(
                    urllib.request.Request(location, headers={"User-Agent": "issue-44-artifact-forensics"}),
                    timeout=180,
                )
                status = response.status
            except (urllib.error.URLError, TimeoutError, OSError):
                return False, 0, "signed-download-unavailable"
    if response is None or status != 200:
        return False, status, "artifact-download-unavailable"

    written = 0
    try:
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with response, destination.open("wb") as output:
            while True:
                chunk = response.read(CHUNK_SIZE)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAX_DOWNLOAD_BYTES:
                    output.close()
                    destination.unlink(missing_ok=True)
                    return False, status, "compressed-download-size-limit"
                output.write(chunk)
        if written < 4:
            destination.unlink(missing_ok=True)
            return False, status, "empty-or-truncated-download"
        return True, status, "downloaded"
    except (OSError, urllib.error.URLError):
        destination.unlink(missing_ok=True)
        return False, 0, "artifact-download-io-error"


def scan_gitleaks(gitleaks: str, config: Path, exposure: Path,
                  reports: Path, state: ScanState):
    report = reports / "artifacts.json"
    process = subprocess.run([
        gitleaks, "dir", str(exposure), "--config=" + str(config),
        "--redact=100", "--report-format=json", "--report-path=" + str(report),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    findings = None
    if report.is_file():
        try:
            findings = json.loads(report.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            findings = None
    findings = validate_gitleaks_result(process.returncode, report.is_file(), findings)
    for finding in findings:
        reported_file = str(finding.get("File", ""))
        try:
            candidate = Path(reported_file)
            relative = (
                candidate.resolve().relative_to(exposure.resolve()).as_posix()
                if candidate.is_absolute() else candidate.as_posix()
            )
        except (OSError, ValueError):
            relative = ""
        if relative not in state.manifest:
            state.record_incomplete("gitleaks-report", reported_file, "finding-source-not-mapped")
    return findings


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GITHUB_TOKEN"]
    gitleaks = os.environ["GITLEAKS_BIN"]
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    current_run_id = int(os.environ.get("GITHUB_RUN_ID", "0") or "0")
    api = "https://api.github.com/repos/" + repo
    config = workspace / "scripts/security/issue-44-gitleaks.toml"
    root = runner_temp / "issue-44-artifact-forensics"
    exposure, reports, downloads = root / "extracted", root / "reports", root / "downloads"

    if not token:
        raise ForensicsError("GITHUB_TOKEN is missing")
    if not config.is_file():
        raise ForensicsError("custom Gitleaks configuration is missing")
    version = subprocess.run(
        [gitleaks, "version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, check=False,
    )
    if version.returncode != 0 or GITLEAKS_VERSION not in version.stdout:
        raise ForensicsError("Gitleaks version mismatch")

    if root.exists():
        shutil.rmtree(root)
    for directory in (root, exposure, reports, downloads):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(directory, 0o700)

    state = ScanState(exposure)
    runs, expected_runs = list_endpoint(api + "/actions/runs", "workflow_runs")
    print(f"ACTIONS_RUNS_ENUMERATED={len(runs)}/{expected_runs}", flush=True)

    artifacts_listed = artifacts_downloaded = expired_artifacts = skipped_current_run = 0
    inventory = []
    for index, run in enumerate(runs, start=1):
        run_id = int(run["id"])
        if current_run_id and run_id == current_run_id:
            skipped_current_run += 1
            continue
        artifacts, expected_artifacts = list_endpoint(
            api + "/actions/runs/" + str(run_id) + "/artifacts", "artifacts"
        )
        validate_inventory(artifacts, expected_artifacts)
        for artifact in artifacts:
            artifacts_listed += 1
            artifact_id = int(artifact["id"])
            artifact_name = safe_text(artifact.get("name"), 160)
            if artifact.get("expired") is True:
                expired_artifacts += 1
                continue
            archive_path = downloads / (str(artifact_id) + ".zip")
            origin = f"run:{run_id}/artifact:{artifact_id}/{artifact_name}"
            ok, http_status, reason = download_archive(
                api + "/actions/artifacts/" + str(artifact_id) + "/zip", archive_path
            )
            if not ok:
                state.record_incomplete(origin, "<archive>", reason + "-http-" + str(http_status))
                continue

            before_quarantine = len(state.quarantined)
            before_incomplete = len(state.incomplete)
            inspect_zip(archive_path, exposure / str(artifact_id), origin, state)
            archive_path.unlink(missing_ok=True)
            artifacts_downloaded += 1
            inventory.append({
                "run_id": run_id, "artifact_id": artifact_id, "name": artifact_name,
                "quarantined_entries": len(state.quarantined) - before_quarantine,
                "incomplete_entries": len(state.incomplete) - before_incomplete,
            })
        if index % 100 == 0:
            print(
                f"ACTIONS_RUNS_PROCESSED={index} ARTIFACTS_DOWNLOADED={artifacts_downloaded}",
                flush=True,
            )

    (root / "inventory.json").write_text(
        json.dumps(inventory, separators=(",", ":")), encoding="utf-8"
    )
    findings = scan_gitleaks(gitleaks, config, exposure, reports, state)

    print(f"ARTIFACTS_LISTED={artifacts_listed} DOWNLOADED={artifacts_downloaded}", flush=True)
    print(f"ARTIFACTS_EXPIRED_NOT_RETAINED={expired_artifacts}", flush=True)
    print(f"CURRENT_FORENSIC_RUN_SKIPPED={skipped_current_run}", flush=True)
    print(f"EXTRACTED_FILES={state.total_files} UNCOMPRESSED_BYTES={state.total_bytes}", flush=True)
    print(f"UNSAFE_ENTRIES_QUARANTINED={len(state.quarantined)}", flush=True)
    for item in state.quarantined:
        print(
            "QUARANTINED_ENTRY origin=" + safe_text(item["origin"]) +
            " member=" + safe_text(item["member"]) + " reason=" + item["reason"], flush=True
        )
    print(f"INCOMPLETE_ITEMS={len(state.incomplete)}", flush=True)
    for item in state.incomplete:
        print(
            "UNSCANNED_ITEM origin=" + safe_text(item["origin"]) +
            " member=" + safe_text(item["member"]) + " reason=" + item["reason"], flush=True
        )

    print(f"GITLEAKS_EXIT_CODE={0 if not findings else 1} FINDINGS={len(findings)}", flush=True)
    for finding in findings[:250]:
        reported_file = str(finding.get("File", ""))
        try:
            candidate = Path(reported_file)
            relative = (
                candidate.resolve().relative_to(exposure.resolve()).as_posix()
                if candidate.is_absolute() else candidate.as_posix()
            )
        except (OSError, ValueError):
            relative = ""
        source = state.manifest.get(relative, {})
        print(
            "ARTIFACT_FINDING rule=" + safe_text(finding.get("RuleID"), 100) +
            " origin=" + safe_text(source.get("origin", "UNMAPPED")) +
            " member=" + safe_text(source.get("member", reported_file)) +
            " line=" + str(finding.get("StartLine", ""),), flush=True
        )

    summary = [
        "# Issue #44 — retained Actions artifact forensics", "",
        f"- Actions runs enumerated: {len(runs)} / {expected_runs}.",
        f"- Current forensic run excluded (still active): {skipped_current_run}.",
        f"- Artifacts listed / downloaded: {artifacts_listed} / {artifacts_downloaded}.",
        f"- Expired artifacts not retained: {expired_artifacts}.",
        f"- Files extracted: {state.total_files}; uncompressed bytes: {state.total_bytes}.",
        f"- Unsafe member paths quarantined and scanned: {len(state.quarantined)}.",
        f"- Items that could not be fully scanned: {len(state.incomplete)}.",
        f"- Gitleaks findings: {len(findings)}.",
    ]
    for item in state.quarantined:
        summary.append(
            "- Quarantined: " + safe_text(item["origin"]) + " :: " +
            safe_text(item["member"]) + " (" + item["reason"] + ")."
        )
    for item in state.incomplete:
        summary.append(
            "- INCOMPLETE: " + safe_text(item["origin"]) + " :: " +
            safe_text(item["member"]) + " (" + item["reason"] + ")."
        )
    for finding in findings[:100]:
        reported_file = str(finding.get("File", ""))
        try:
            candidate = Path(reported_file)
            relative = (
                candidate.resolve().relative_to(exposure.resolve()).as_posix()
                if candidate.is_absolute() else candidate.as_posix()
            )
        except (OSError, ValueError):
            relative = ""
        source = state.manifest.get(relative, {})
        summary.append(
            "- FINDING: rule=" + safe_text(finding.get("RuleID"), 100) +
            "; origin=" + safe_text(source.get("origin", "UNMAPPED")) +
            "; member=" + safe_text(source.get("member", reported_file)) +
            "; line=" + str(finding.get("StartLine", "")) + "."
        )
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write("\n".join(summary) + "\n")

    if state.incomplete:
        print("ARTIFACT_FORENSICS_VERDICT=INCOMPLETE", flush=True)
        return 2
    if findings:
        print("ARTIFACT_FORENSICS_VERDICT=FINDINGS_REQUIRE_TRIAGE", flush=True)
        return 1
    print("ARTIFACT_FORENSICS_VERDICT=COMPLETE_NO_GITLEAKS_MATCHES", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("ARTIFACT_FORENSICS_ERROR=" + safe_text(error), file=sys.stderr, flush=True)
        sys.exit(2)
