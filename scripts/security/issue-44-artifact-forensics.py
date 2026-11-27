#!/usr/bin/env python3
"""Bounded, read-only forensics for retained GitHub Actions artifact archives.

Unsafe ZIP paths are quarantined under generated names and their bytes are scanned.
Any archive/member that cannot be completely inspected fails closed as INCOMPLETE.
"""
import json, os, re, shutil, stat, subprocess, sys, time
from datetime import datetime, timedelta, timezone
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


def parse_current_run_id(raw_value: str | None) -> int:
    """Parse the current workflow run id from the Actions environment."""
    if raw_value in (None, ""):
        return 0
    try:
        value = int(raw_value)
    except (TypeError, ValueError) as error:
        raise ForensicsError("GITHUB_RUN_ID is not a valid integer") from error
    if value < 0:
        raise ForensicsError("GITHUB_RUN_ID cannot be negative")
    return value


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


def select_artifacts_snapshot(
    artifacts: list[dict[str, Any]], cutoff: str
) -> tuple[list[dict[str, Any]], int, int]:
    """Return non-expired artifacts created no later than the immutable snapshot cutoff."""
    try:
        cutoff_time = datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    except ValueError as error:
        raise ForensicsError("invalid artifact snapshot cutoff") from error

    selected = []
    expired = 0
    newer = 0
    for artifact in artifacts:
        created_at = artifact.get("created_at")
        if not isinstance(created_at, str):
            raise ForensicsError("artifact inventory item is missing created_at")
        try:
            created_time = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ForensicsError("artifact inventory item has invalid created_at") from error
        if created_time.tzinfo is None:
            raise ForensicsError("artifact created_at must include a timezone")
        if created_time > cutoff_time:
            newer += 1
        elif artifact.get("expired") is True:
            expired += 1
        else:
            selected.append(artifact)
    return selected, expired, newer


def select_completed_runs_snapshot(
    runs: list[dict[str, Any]], cutoff: str, current_run_id: int
) -> tuple[list[dict[str, Any]], int, int, int]:
    """Select completed historical runs and count active/current/out-of-snapshot runs."""
    try:
        cutoff_time = datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    except ValueError as error:
        raise ForensicsError("invalid Actions run snapshot cutoff") from error

    selected = []
    current_skipped = 0
    noncompleted_skipped = 0
    newer = 0
    for run in runs:
        created_at = run.get("created_at")
        if not isinstance(created_at, str):
            raise ForensicsError("Actions run inventory item is missing created_at")
        try:
            created_time = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ForensicsError("Actions run inventory item has invalid created_at") from error
        if created_time.tzinfo is None:
            raise ForensicsError("Actions run created_at must include a timezone")
        if created_time > cutoff_time:
            newer += 1
        elif int(run["id"]) == current_run_id:
            current_skipped += 1
        elif run.get("status") != "completed":
            noncompleted_skipped += 1
        else:
            selected.append(run)
    return selected, current_skipped, noncompleted_skipped, newer


def select_artifacts_after_cutoff(
    artifacts: list[dict[str, Any]], cutoff: str
) -> tuple[list[dict[str, Any]], int, int]:
    """Return every non-expired artifact created strictly after a previous scan cutoff."""
    try:
        cutoff_time = datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    except ValueError as error:
        raise ForensicsError("invalid previous artifact scan cutoff") from error
    if cutoff_time.tzinfo is None:
        raise ForensicsError("previous artifact cutoff must include a timezone")

    selected = []
    expired_after_cutoff = 0
    at_or_before_cutoff = 0
    for artifact in artifacts:
        created_at = artifact.get("created_at")
        if not isinstance(created_at, str):
            raise ForensicsError("artifact inventory item is missing created_at")
        try:
            created_time = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ForensicsError("artifact inventory item has invalid created_at") from error
        if created_time.tzinfo is None:
            raise ForensicsError("artifact created_at must include a timezone")
        if created_time <= cutoff_time:
            at_or_before_cutoff += 1
        elif artifact.get("expired") is True:
            expired_after_cutoff += 1
        else:
            selected.append(artifact)
    return selected, expired_after_cutoff, at_or_before_cutoff


def select_completed_runs_after_cutoff(
    runs: list[dict[str, Any]], cutoff: str, current_run_id: int
) -> tuple[list[dict[str, Any]], int, list[dict[str, Any]], int]:
    """Select all completed workflow runs created strictly after a previous scan cutoff."""
    try:
        cutoff_time = datetime.fromisoformat(cutoff.replace("Z", "+00:00"))
    except ValueError as error:
        raise ForensicsError("invalid previous workflow-run scan cutoff") from error
    if cutoff_time.tzinfo is None:
        raise ForensicsError("previous workflow-run cutoff must include a timezone")

    selected = []
    current_skipped = 0
    noncompleted = []
    at_or_before_cutoff = 0
    for run in runs:
        created_at = run.get("created_at")
        if not isinstance(created_at, str):
            raise ForensicsError("Actions run inventory item is missing created_at")
        try:
            created_time = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ForensicsError("Actions run inventory item has invalid created_at") from error
        if created_time.tzinfo is None:
            raise ForensicsError("Actions run created_at must include a timezone")
        if created_time <= cutoff_time:
            at_or_before_cutoff += 1
        elif int(run["id"]) == current_run_id:
            current_skipped += 1
        elif run.get("status") != "completed":
            noncompleted.append(run)
        else:
            selected.append(run)
    return selected, current_skipped, noncompleted, at_or_before_cutoff


def validate_stable_inventory(
    first: list[dict[str, Any]], second: list[dict[str, Any]], id_key: str = "id"
) -> None:
    """Reject artifact-list drift between two complete repository-wide snapshots."""
    first_ids = [str(item.get(id_key, "")) for item in first]
    second_ids = [str(item.get(id_key, "")) for item in second]
    if len(first_ids) != len(second_ids) or set(first_ids) != set(second_ids):
        raise ForensicsError("repository artifact inventory changed during snapshot confirmation")


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
    if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
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
            raw_name = info.filename
            unsafe_reason = _unsafe_member_reason(info, raw_name)
            # Skip only ordinary directories. A symlink/special/traversal directory
            # entry must be recorded just like an unsafe file member.
            if info.is_dir() and unsafe_reason is None:
                continue
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
                target = destination / "_quarantine" / f"entry-{index:06d}.txt"
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


MAX_RUNS_PER_SEARCH = 900


def partition_time_range(
    start, end, count_provider, max_results: int = MAX_RUNS_PER_SEARCH,
    expected_count: int | None = None,
):
    """Split a GitHub created-time query and reconcile every child count to its parent."""
    if start > end:
        raise ForensicsError("workflow run time range is inverted")
    expected = count_provider(start, end) if expected_count is None else expected_count
    if not isinstance(expected, int) or expected < 0:
        raise ForensicsError("workflow run count probe returned an invalid count")
    if expected <= max_results:
        return [(start, end, expected)]
    duration = int((end - start).total_seconds())
    if duration < 1:
        raise ForensicsError(
            "more than the GitHub workflow-run search limit share a one-second timestamp"
        )
    midpoint = start + timedelta(seconds=duration // 2)
    right_start = midpoint + timedelta(seconds=1)
    left = partition_time_range(start, midpoint, count_provider, max_results)
    right = partition_time_range(right_start, end, count_provider, max_results)
    if sum(partition[2] for partition in left + right) != expected:
        raise ForensicsError("workflow run partition counts do not reconcile parent total")
    return left + right


def list_workflow_runs_partitioned(api: str, cutoff: str, start_after: str | None = None):
    """Enumerate every workflow run using disjoint created-time ranges below GitHub's 1,000 cap."""
    try:
        end = datetime.fromisoformat(cutoff.replace("Z", "+00:00")).replace(microsecond=0)
    except ValueError as error:
        raise ForensicsError("invalid workflow-run snapshot cutoff") from error
    if start_after is None:
        start = datetime(2000, 1, 1, tzinfo=timezone.utc)
    else:
        try:
            start = datetime.fromisoformat(start_after.replace("Z", "+00:00")).replace(microsecond=0)
        except ValueError as error:
            raise ForensicsError("invalid workflow-run lower snapshot cutoff") from error
        if start.tzinfo is None:
            raise ForensicsError("workflow-run lower cutoff must include a timezone")
        # GitHub's created range is inclusive; advance one whole second to select only newer runs.
        start += timedelta(seconds=1)
    if start > end:
        return [], 0, 0

    def count_provider(range_start, range_end):
        url = (
            api + "/actions/runs?created=" +
            range_start.strftime("%Y-%m-%dT%H:%M:%SZ") + ".." +
            range_end.strftime("%Y-%m-%dT%H:%M:%SZ") +
            "&per_page=1&page=1"
        )
        status, payload = api_json(url)
        if status != 200 or not isinstance(payload, dict):
            raise ForensicsError(
                f"workflow run range count probe failed: http={status}"
            )
        count = payload.get("total_count")
        if not isinstance(count, int) or count < 0:
            raise ForensicsError("workflow run range count probe omitted total_count")
        return count

    partitions = partition_time_range(start, end, count_provider)
    all_runs = []
    expected_total = 0
    for range_start, range_end, probed_count in partitions:
        if probed_count == 0:
            continue
        url = (
            api + "/actions/runs?created=" +
            range_start.strftime("%Y-%m-%dT%H:%M:%SZ") + ".." +
            range_end.strftime("%Y-%m-%dT%H:%M:%SZ")
        )
        range_runs, actual_count = retry_inventory_call(
            lambda: list_endpoint(url, "workflow_runs")
        )
        if actual_count != probed_count:
            raise ForensicsError(
                "workflow run range total_count changed between probe and pagination"
            )
        all_runs.extend(range_runs)
        expected_total += probed_count

    validate_inventory(all_runs, expected_total)
    return all_runs, expected_total, len(partitions)


def retry_inventory_call(fetch, attempts: int = 5):
    """Retry only inventory-drift errors; never suppress authorization, HTTP, or schema failures."""
    for attempt in range(attempts):
        try:
            return fetch()
        except ForensicsError as error:
            message = str(error)
            transient = (
                "total_count changed during" in message
                or "inventory count mismatch" in message
                or "repository artifact inventory changed during" in message
                or "repository artifact total_count changed during" in message
                or "Actions run total_count changed during" in message
                or "workflow run partition counts do not reconcile parent total" in message
            )
            if not transient or attempt + 1 == attempts:
                raise
            delay = min(5 * (2 ** attempt), 30)
            print(
                f"INVENTORY_SNAPSHOT_RETRY={attempt + 1}/{attempts - 1} "
                f"REASON=transient-pagination-drift WAIT_SECONDS={delay}",
                flush=True,
            )
            time.sleep(delay)
    raise ForensicsError("inventory retry budget exhausted")


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
    """Stream an artifact ZIP to private disk; refresh temporary signed URLs on transient failures."""
    last_status = 0
    last_reason = "signed-download-unavailable"
    for attempt in range(3):
        destination.unlink(missing_ok=True)
        response, status, headers = api_open(url)
        if response is None and status in (301, 302, 303, 307, 308):
            location = headers.get("Location") or headers.get("location")
            if not location:
                return False, status, "signed-download-location-missing"
            try:
                response = urllib.request.urlopen(
                    urllib.request.Request(location, headers={"User-Agent": "issue-44-artifact-forensics"}),
                    timeout=180,
                )
                status = response.status
            except (urllib.error.URLError, TimeoutError, OSError):
                last_status = 0
                last_reason = "signed-download-unavailable"
                if attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                return False, last_status, last_reason
        if response is None or status != 200:
            last_status = status
            last_reason = "artifact-download-unavailable"
            if (status == 0 or status == 429 or status in (500, 502, 503, 504)) and attempt < 2:
                time.sleep(2 ** attempt)
                continue
            return False, last_status, last_reason

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
                last_status = status
                last_reason = "empty-or-truncated-download"
                if attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                return False, last_status, last_reason
            return True, status, "downloaded"
        except (OSError, urllib.error.URLError):
            destination.unlink(missing_ok=True)
            last_status = 0
            last_reason = "artifact-download-io-error"
            if attempt < 2:
                time.sleep(2 ** attempt)
                continue
            return False, last_status, last_reason

    destination.unlink(missing_ok=True)
    return False, last_status, last_reason


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



def deferred_run_records(runs: list[dict[str, Any]], current_run_id: int) -> list[dict[str, Any]]:
    """Describe active runs in this incremental snapshot without treating them as scan failures."""
    records = []
    for run in runs:
        if run.get("status") == "completed":
            continue
        records.append({
            "run_id": int(run["id"]),
            "status": safe_text(run.get("status"), 40),
            "workflow": safe_text(run.get("name"), 120),
            "created_at": safe_text(run.get("created_at"), 40),
            "is_current_run": int(run["id"]) == current_run_id,
        })
    return sorted(records, key=lambda item: item["run_id"])


def finding_identity(finding: dict[str, Any], exposure: Path,
                     file_manifest: dict[str, dict[str, str]]):
    """Resolve a redacted Gitleaks finding to its exact Actions source location."""
    reported_file = str(finding.get("File", ""))
    try:
        candidate = Path(reported_file)
        relative = (
            candidate.resolve().relative_to(exposure.resolve()).as_posix()
            if candidate.is_absolute() else candidate.as_posix()
        )
    except (OSError, ValueError):
        return None, None
    source = file_manifest.get(relative)
    if not source:
        return None, None
    try:
        line = int(finding.get("StartLine"))
    except (TypeError, ValueError):
        return None, source
    rule_id = str(finding.get("RuleID", ""))
    if not rule_id:
        return None, source
    return (rule_id, source["origin"], source["member"], line), source


def load_finding_classifications(path: Path):
    """Load exact source-location verdicts; never allow a rule-wide or path-wide suppression."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ForensicsError("finding classification manifest is missing or invalid JSON") from error
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ForensicsError("unsupported finding classification manifest schema")
    entries = payload.get("classifications")
    if not isinstance(entries, list):
        raise ForensicsError("finding classification manifest omitted classifications")
    allowed_verdicts = {"NON_SECRET_SYNTHETIC_TEST_DATA", "LOCAL_EPHEMERAL_NOT_HOSTED"}
    index = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ForensicsError("finding classification entry is not an object")
        try:
            key = (
                str(entry["rule_id"]), str(entry["origin"]),
                str(entry["member"]), int(entry["line"]),
            )
            classification = str(entry["classification"])
            verdict = str(entry["verdict"])
            rationale = str(entry["rationale"])
        except (KeyError, TypeError, ValueError) as error:
            raise ForensicsError("finding classification entry is missing required fields") from error
        if not all(key) or not classification or not rationale or verdict not in allowed_verdicts:
            raise ForensicsError("finding classification entry contains an invalid value")
        if key in index:
            raise ForensicsError("finding classification manifest contains duplicate source keys")
        index[key] = {
            "rule_id": key[0], "origin": key[1], "member": key[2], "line": key[3],
            "classification": classification, "verdict": verdict, "rationale": rationale,
            "baseline_occurrences": int(entry.get("baseline_occurrences", 0)),
            "observed_count": 0,
        }
    return index


def classify_gitleaks_findings(findings: list[dict[str, Any]], exposure: Path,
                               file_manifest: dict[str, dict[str, str]],
                               classification_index: dict):
    """Classify only exact rule/origin/member/line matches; everything else remains unclassified."""
    classified = {}
    unclassified = []
    for finding in findings:
        key, source = finding_identity(finding, exposure, file_manifest)
        if key is None:
            unclassified.append({
                "rule_id": safe_text(finding.get("RuleID"), 100),
                "origin": safe_text((source or {}).get("origin", "UNMAPPED"), 300),
                "member": safe_text((source or {}).get("member", finding.get("File", "UNMAPPED")), 300),
                "line": finding.get("StartLine", ""),
            })
            continue
        entry = classification_index.get(key)
        if entry is None:
            unclassified.append({
                "rule_id": safe_text(key[0], 100), "origin": safe_text(key[1], 300),
                "member": safe_text(key[2], 300), "line": key[3],
            })
            continue
        if key not in classified:
            classified[key] = dict(entry)
        classified[key]["observed_count"] += 1
    return list(classified.values()), unclassified

def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GITHUB_TOKEN"]
    gitleaks = os.environ["GITLEAKS_BIN"]
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    current_run_id = parse_current_run_id(os.environ.get("GITHUB_RUN_ID"))
    prior_run_cutoff = os.environ.get("ISSUE_44_PRIOR_RUN_CUTOFF")
    prior_artifact_cutoff = os.environ.get("ISSUE_44_PRIOR_ARTIFACT_CUTOFF")
    incremental_mode = bool(prior_run_cutoff or prior_artifact_cutoff)
    if incremental_mode and not (prior_run_cutoff and prior_artifact_cutoff):
        raise ForensicsError("both previous Actions-run and artifact cutoffs are required")
    if incremental_mode:
        # The incremental pass uses the immutable cutoffs from the last complete inventory.
        # The current run is explicitly excluded because its log is still active.
        snapshot_cutoff = prior_artifact_cutoff
        run_snapshot_cutoff = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        # Full-snapshot mode used by the final PR scan.
        snapshot_cutoff = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
        run_snapshot_cutoff = (
            datetime.now(timezone.utc) - timedelta(minutes=1)
        ).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
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
    deferred_runs = []
    deferred_artifacts = []

    # Snapshot all completed workflow runs first. Logs are ZIP archives too, and
    # the previous audit's aggregate unsafe-entry count covered both logs and artifacts.
    runs_all, expected_runs, run_partition_count = retry_inventory_call(
        lambda: list_workflow_runs_partitioned(
            api,
            run_snapshot_cutoff,
            start_after=prior_run_cutoff if incremental_mode else None,
        )
    )
    runs_confirmation, confirmed_runs_total, confirmed_partitions = retry_inventory_call(
        lambda: list_workflow_runs_partitioned(
            api,
            run_snapshot_cutoff,
            start_after=prior_run_cutoff if incremental_mode else None,
        )
    )
    if expected_runs != confirmed_runs_total:
        raise ForensicsError("Actions run total_count changed during snapshot confirmation")
    if run_partition_count != confirmed_partitions:
        raise ForensicsError("workflow run search partition count changed during snapshot confirmation")
    validate_stable_inventory(runs_all, runs_confirmation)
    if incremental_mode:
        selected_runs, current_run_skipped, noncompleted_runs, runs_at_or_before_cutoff = (
            select_completed_runs_after_cutoff(runs_all, prior_run_cutoff, current_run_id)
        )
        noncompleted_runs_skipped = len(noncompleted_runs)
        newer_runs = 0
        # Active runs are deferred and re-scanned on workflow completion. Their transient
        # in-progress state is not a corrupt archive or failed download.
        deferred_runs = deferred_run_records(runs_all, current_run_id)
        print(
            f"RUNS_AT_OR_BEFORE_PRIOR_CUTOFF={runs_at_or_before_cutoff} "
            f"NONCOMPLETED_AFTER_CUTOFF={noncompleted_runs_skipped} "
            f"DEFERRED_RUNS={len(deferred_runs)}",
            flush=True,
        )
        for item in deferred_runs:
            print(
                "DEFERRED_RUN id=" + str(item["run_id"]) +
                " status=" + item["status"] +
                " workflow=" + item["workflow"] +
                " current=" + str(item["is_current_run"]).lower(),
                flush=True,
            )
    else:
        selected_runs, current_run_skipped, noncompleted_runs_skipped, newer_runs = (
            select_completed_runs_snapshot(runs_all, run_snapshot_cutoff, current_run_id)
        )
    print(
        f"ACTIONS_RUNS_ENUMERATED={len(runs_all)}/{expected_runs} "
        f"RUN_SEARCH_PARTITIONS={run_partition_count} "
        f"RUN_SNAPSHOT_CUTOFF={run_snapshot_cutoff} "
        f"COMPLETED_RUNS_IN_SNAPSHOT={len(selected_runs)} "
        f"CURRENT_RUN_SKIPPED={current_run_skipped} "
        f"NONCOMPLETED_RUNS_SKIPPED={noncompleted_runs_skipped} "
        f"NEWER_RUNS={newer_runs}",
        flush=True,
    )

    run_logs_downloaded = 0
    run_log_inventory = []
    for run in selected_runs:
        print(
            "RUN_LOG_TO_SCAN id=" + str(int(run["id"])) +
            " workflow=" + safe_text(run.get("name"), 120) +
            " created_at=" + safe_text(run.get("created_at"), 40) +
            " branch=" + safe_text(run.get("head_branch"), 120),
            flush=True,
        )
    for index, run in enumerate(selected_runs, start=1):
        run_id = int(run["id"])
        origin = f"run:{run_id}/logs"
        archive_path = downloads / f"run-{run_id}-logs.zip"
        ok, http_status, reason = download_archive(
            api + "/actions/runs/" + str(run_id) + "/logs", archive_path
        )
        if not ok:
            state.record_incomplete(
                origin, "<archive>", reason + "-http-" + str(http_status)
            )
            run_log_inventory.append({"run_id": run_id, "downloaded": False})
            continue

        before_quarantine = len(state.quarantined)
        before_incomplete = len(state.incomplete)
        inspect_zip(archive_path, exposure / "logs" / str(run_id), origin, state)
        archive_path.unlink(missing_ok=True)
        run_logs_downloaded += 1
        run_log_inventory.append({
            "run_id": run_id,
            "downloaded": True,
            "quarantined_entries": len(state.quarantined) - before_quarantine,
            "incomplete_entries": len(state.incomplete) - before_incomplete,
        })
        if index % 100 == 0:
            print(f"ACTIONS_RUN_LOGS_PROCESSED={index} DOWNLOADED={run_logs_downloaded}", flush=True)

    (root / "run-log-inventory.json").write_text(
        json.dumps(run_log_inventory, separators=(",", ":")), encoding="utf-8"
    )

    artifacts_all, expected_artifacts = retry_inventory_call(
        lambda: list_endpoint(api + "/actions/artifacts", "artifacts")
    )
    confirmation, confirmation_total = retry_inventory_call(
        lambda: list_endpoint(api + "/actions/artifacts", "artifacts")
    )
    if expected_artifacts != confirmation_total:
        raise ForensicsError("repository artifact total_count changed during snapshot confirmation")
    validate_stable_inventory(artifacts_all, confirmation)
    if incremental_mode:
        selected_artifacts, expired_artifacts, artifacts_at_or_before_cutoff = (
            select_artifacts_after_cutoff(artifacts_all, prior_artifact_cutoff)
        )
        artifacts_newer_than_cutoff = 0
        cutoff_time = datetime.fromisoformat(prior_artifact_cutoff.replace("Z", "+00:00"))
        for artifact in artifacts_all:
            created_time = datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
            if created_time > cutoff_time and artifact.get("expired") is True:
                state.record_incomplete(
                    f"artifact:{int(artifact['id'])}/{safe_text(artifact.get('name'), 160)}",
                    "<archive>", "artifact-expired-after-prior-cutoff",
                )
        print(f"ARTIFACTS_AT_OR_BEFORE_PRIOR_CUTOFF={artifacts_at_or_before_cutoff}", flush=True)
        deferred_run_ids = {item["run_id"] for item in deferred_runs}
        deferred_artifacts = []
        artifacts_to_scan = []
        for artifact in selected_artifacts:
            workflow_run = artifact.get("workflow_run") if isinstance(artifact.get("workflow_run"), dict) else {}
            source_run_id = int(workflow_run.get("id", 0) or 0)
            if source_run_id in deferred_run_ids:
                deferred_artifacts.append(artifact)
            else:
                artifacts_to_scan.append(artifact)
        selected_artifacts = artifacts_to_scan
        for artifact in deferred_artifacts:
            workflow_run = artifact.get("workflow_run") if isinstance(artifact.get("workflow_run"), dict) else {}
            print(
                "DEFERRED_ARTIFACT id=" + str(int(artifact["id"])) +
                " run_id=" + str(int(workflow_run.get("id", 0))) +
                " name=" + safe_text(artifact.get("name"), 160),
                flush=True,
            )
        print(
            f"DEFERRED_ARTIFACTS={len(deferred_artifacts)} "
            f"DEFERRED_ITEMS={len(deferred_runs) + len(deferred_artifacts)}",
            flush=True,
        )
    else:
        deferred_runs = []
        deferred_artifacts = []
        selected_artifacts, expired_artifacts, artifacts_newer_than_cutoff = select_artifacts_snapshot(
            artifacts_all, snapshot_cutoff
        )
    artifacts_listed = len(artifacts_all)
    print(
        f"ARTIFACTS_ENUMERATED={artifacts_listed}/{expected_artifacts} "
        f"IN_SNAPSHOT={len(selected_artifacts)} EXPIRED={expired_artifacts} "
        f"NEWER_THAN_CUTOFF={artifacts_newer_than_cutoff}",
        flush=True,
    )

    artifacts_downloaded = 0
    inventory = []
    for artifact in selected_artifacts:
        workflow_run = artifact.get("workflow_run") if isinstance(artifact.get("workflow_run"), dict) else {}
        print(
            "ARTIFACT_TO_SCAN id=" + str(int(artifact["id"])) +
            " run_id=" + str(int(workflow_run.get("id", 0))) +
            " name=" + safe_text(artifact.get("name"), 160) +
            " created_at=" + safe_text(artifact.get("created_at"), 40),
            flush=True,
        )
    for index, artifact in enumerate(selected_artifacts, start=1):
        artifact_id = int(artifact["id"])
        artifact_name = safe_text(artifact.get("name"), 160)
        workflow_run = artifact.get("workflow_run")
        if not isinstance(workflow_run, dict) or not workflow_run.get("id"):
            state.record_incomplete(
                f"artifact:{artifact_id}/{artifact_name}", "<workflow_run>",
                "artifact-source-run-id-missing",
            )
            continue
        run_id = int(workflow_run["id"])
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
                f"ARTIFACTS_PROCESSED={index} DOWNLOADED={artifacts_downloaded}",
                flush=True,
            )

    (root / "inventory.json").write_text(
        json.dumps(inventory, separators=(",", ":")), encoding="utf-8"
    )
    findings = scan_gitleaks(gitleaks, config, exposure, reports, state)
    classified_findings = []
    unclassified_findings = []
    if incremental_mode:
        classification_path = workspace / "scripts/security/issue-44-findings-classification.json"
        classification_index = load_finding_classifications(classification_path)
        classified_findings, unclassified_findings = classify_gitleaks_findings(
            findings, exposure, state.manifest, classification_index
        )
        classified_occurrences = sum(item["observed_count"] for item in classified_findings)
        print(
            f"FINDINGS_CLASSIFIED={classified_occurrences}/{len(findings)} "
            f"UNCLASSIFIED={len(unclassified_findings)}",
            flush=True,
        )
        for item in classified_findings:
            print(
                "CLASSIFIED_FINDING rule=" + safe_text(item["rule_id"], 100) +
                " classification=" + safe_text(item["classification"], 100) +
                " verdict=" + safe_text(item["verdict"], 100) +
                " occurrences=" + str(item["observed_count"]) +
                " origin=" + safe_text(item["origin"], 300) +
                " member=" + safe_text(item["member"], 300) +
                " line=" + str(item["line"]),
                flush=True,
            )
            if item["rule_id"] == "supabase-secret-key":
                print(
                    "SUPABASE_SECRET_KEY_VERDICT=" + safe_text(item["verdict"], 100) +
                    " origin=" + safe_text(item["origin"], 300) +
                    " member=" + safe_text(item["member"], 300) +
                    " line=" + str(item["line"]),
                    flush=True,
                )
        for item in unclassified_findings:
            print(
                "UNCLASSIFIED_FINDING rule=" + safe_text(item["rule_id"], 100) +
                " origin=" + safe_text(item["origin"], 300) +
                " member=" + safe_text(item["member"], 300) +
                " line=" + str(item["line"]),
                flush=True,
            )

    print(
        f"ACTIONS_RUN_LOGS_LISTED={len(selected_runs)} DOWNLOADED={run_logs_downloaded} "
        f"CURRENT_SKIPPED={current_run_skipped} NONCOMPLETED_SKIPPED={noncompleted_runs_skipped}",
        flush=True,
    )
    print(
        f"ARTIFACTS_LISTED={artifacts_listed} DOWNLOADED={artifacts_downloaded} "
        f"NEWER_THAN_SNAPSHOT={artifacts_newer_than_cutoff}",
        flush=True,
    )
    print(f"ARTIFACTS_EXPIRED_NOT_RETAINED={expired_artifacts}", flush=True)
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
        source = state.manifest.get(relative, {})
        print(
            "FORENSIC_FINDING rule=" + safe_text(finding.get("RuleID"), 100) +
            " origin=" + safe_text(source.get("origin", "UNMAPPED")) +
            " member=" + safe_text(source.get("member", reported_file)) +
            " line=" + str(finding.get("StartLine", ""),), flush=True
        )

    summary = [
        "# Issue #44 — retained Actions logs and artifact forensics", "",
        f"- Artifact snapshot cutoff UTC: {snapshot_cutoff}.",
        f"- Incremental after prior cutoffs: {incremental_mode}.",
        f"- Workflow-run snapshot cutoff UTC: {run_snapshot_cutoff}.",
        f"- Actions runs enumerated: {len(runs_all)} / {expected_runs} across {run_partition_count} disjoint time partitions; completed logs selected: {len(selected_runs)}.",
        f"- Current forensic run skipped: {current_run_skipped}; non-completed runs skipped: {noncompleted_runs_skipped}; newer runs: {newer_runs}.",
        f"- Run logs downloaded: {run_logs_downloaded} / {len(selected_runs)}.",
        f"- Repository artifacts enumerated: {artifacts_listed} / {expected_artifacts}.",
        f"- Artifacts in snapshot / downloaded: {len(selected_artifacts)} / {artifacts_downloaded}.",
        f"- Expired artifacts: {expired_artifacts}; created after snapshot cutoff: {artifacts_newer_than_cutoff}.",
        f"- Files extracted: {state.total_files}; uncompressed bytes: {state.total_bytes}.",
        f"- Unsafe member paths quarantined and scanned: {len(state.quarantined)}.",
        f"- Items that could not be fully scanned: {len(state.incomplete)}.",
        f"- Deferred active runs: {len(deferred_runs)}; non-current runs are passed to the follow-up rescan job.",
        f"- Artifacts deferred with active runs: {len(deferred_artifacts)}.",
        f"- Gitleaks findings: {len(findings)}.",
    ]
    for item in deferred_runs:
        summary.append(
            "- DEFERRED RUN: id=" + str(item["run_id"]) +
            "; status=" + item["status"] + "; workflow=" + item["workflow"] +
            ("; current scanner run." if item["is_current_run"] else "; will be scanned after completion.")
        )
    for artifact in deferred_artifacts:
        workflow_run = artifact.get("workflow_run") if isinstance(artifact.get("workflow_run"), dict) else {}
        summary.append(
            "- DEFERRED ARTIFACT: id=" + str(int(artifact["id"])) +
            "; run_id=" + str(int(workflow_run.get("id", 0))) +
            "; name=" + safe_text(artifact.get("name"), 160) + "."
        )
    if incremental_mode:
        summary.append(
            f"- Findings classified: {sum(item['observed_count'] for item in classified_findings)} / "
            f"{len(findings)}; unclassified: {len(unclassified_findings)}."
        )
        for item in classified_findings:
            summary.append(
                "- CLASSIFIED FINDING: rule=" + safe_text(item["rule_id"], 100) +
                "; classification=" + safe_text(item["classification"], 100) +
                "; verdict=" + safe_text(item["verdict"], 100) +
                "; occurrences=" + str(item["observed_count"]) +
                "; origin=" + safe_text(item["origin"], 300) +
                "; member=" + safe_text(item["member"], 300) +
                "; line=" + str(item["line"]) + "."
            )
        for item in unclassified_findings:
            summary.append(
                "- UNCLASSIFIED FINDING: rule=" + safe_text(item["rule_id"], 100) +
                "; origin=" + safe_text(item["origin"], 300) +
                "; member=" + safe_text(item["member"], 300) +
                "; line=" + str(item["line"]) + "."
            )
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
    if incremental_mode:
        output_path = os.environ.get("GITHUB_OUTPUT")
        if output_path:
            followup_run_ids = [
                str(item["run_id"]) for item in deferred_runs if not item["is_current_run"]
            ]
            with open(output_path, "a", encoding="utf-8") as stream:
                stream.write("deferred_run_ids=" + ",".join(followup_run_ids) + "\n")

    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write("\n".join(summary) + "\n")

    if state.incomplete:
        print("ARTIFACT_FORENSICS_VERDICT=INCOMPLETE", flush=True)
        return 2
    if incremental_mode:
        if unclassified_findings:
            print("ARTIFACT_FORENSICS_VERDICT=UNCLASSIFIED_FINDINGS_REQUIRE_TRIAGE", flush=True)
            return 1
        print("ARTIFACT_FORENSICS_VERDICT=COMPLETE_ALL_FINDINGS_CLASSIFIED", flush=True)
        return 0
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
