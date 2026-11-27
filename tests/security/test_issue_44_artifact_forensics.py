"""Offline security tests for Issue #44 artifact forensics."""
import importlib.util
import io
import json
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path
from datetime import datetime

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/security/issue-44-artifact-forensics.py"
SPEC = importlib.util.spec_from_file_location("issue44_artifact_forensics", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


def make_zip(path: Path, members: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in members.items():
            archive.writestr(name, content)


class ArtifactForensicsTests(unittest.TestCase):
    def test_zip_slip_member_is_quarantined_and_preserved_for_scan(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, exposure = root / "artifact.zip", root / "extracted"
            exposure.mkdir()
            make_zip(source, {"../../outside.txt": b"synthetic fixture content"})
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(source, exposure / "42", "run:7/artifact:42/report", state)
            self.assertFalse((root / "outside.txt").exists())
            self.assertEqual(len(state.quarantined), 1)
            self.assertEqual(state.quarantined[0]["origin"], "run:7/artifact:42/report")
            self.assertEqual(state.quarantined[0]["member"], "../../outside.txt")
            self.assertEqual(state.incomplete, [])
            extracted = list((exposure / "42" / "_quarantine").glob("*.txt"))
            self.assertEqual(len(extracted), 1)
            self.assertEqual(extracted[0].read_bytes(), b"synthetic fixture content")
            self.assertIn(extracted[0].relative_to(exposure).as_posix(), state.manifest)

    def test_symlink_entry_is_quarantined_as_bytes_not_created_as_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, exposure = root / "artifact.zip", root / "extracted"
            exposure.mkdir()
            info = zipfile.ZipInfo("link-to-outside")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(info, b"../../outside.txt")
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(source, exposure / "9", "run:8/artifact:9/logs", state)
            self.assertEqual(state.quarantined[0]["reason"], "symlink-entry")
            self.assertFalse((exposure / "9" / "link-to-outside").is_symlink())
            self.assertEqual(state.incomplete, [])

    def test_directory_symlink_entry_is_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, exposure = root / "artifact.zip", root / "extracted"
            exposure.mkdir()
            info = zipfile.ZipInfo("directory-link/")
            info.create_system = 3
            info.external_attr = (0o120777 << 16)
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(info, b"outside-target")
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(source, exposure / "11", "run:9/artifact:11/logs", state)
            self.assertEqual(len(state.quarantined), 1)
            self.assertEqual(state.quarantined[0]["reason"], "symlink-entry")
            payload = list((exposure / "11" / "_quarantine").glob("*.txt"))
            self.assertEqual(len(payload), 1)
            self.assertEqual(payload[0].read_bytes(), b"outside-target")
            self.assertEqual(state.incomplete, [])

    def test_nested_zip_content_is_recursively_extracted_and_mapped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inner_buffer = io.BytesIO()
            with zipfile.ZipFile(inner_buffer, "w", compression=zipfile.ZIP_DEFLATED) as inner:
                inner.writestr("nested/credential.txt", "synthetic test token placeholder")
            outer, exposure = root / "outer.zip", root / "extracted"
            with zipfile.ZipFile(outer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("inner.zip", inner_buffer.getvalue())
            exposure.mkdir()
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(outer, exposure / "55", "run:10/artifact:55/bundle", state)
            self.assertEqual(state.incomplete, [])
            self.assertTrue(any(
                "inner.zip" in item["origin"] and item["member"] == "nested/credential.txt"
                for item in state.manifest.values()
            ))
            payloads = list((exposure / "55").rglob("credential.txt"))
            self.assertEqual(len(payloads), 1)
            self.assertIn("synthetic test token placeholder", payloads[0].read_text())

    def test_nested_archive_depth_limit_is_incomplete_not_clean(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inner_buffer = io.BytesIO()
            with zipfile.ZipFile(inner_buffer, "w") as inner:
                inner.writestr("leaf.txt", "data")
            outer, exposure = root / "outer.zip", root / "extracted"
            with zipfile.ZipFile(outer, "w") as archive:
                archive.writestr("inner.zip", inner_buffer.getvalue())
            exposure.mkdir()
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(
                outer, exposure / "77", "run:11/artifact:77/bundle", state,
                depth=MODULE.MAX_NESTED_ARCHIVES,
            )
            self.assertTrue(any(
                item["reason"] == "nested-archive-depth-limit" for item in state.incomplete
            ))

    def test_corrupt_zip_is_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, exposure = root / "broken.zip", root / "extracted"
            source.write_bytes(b"not a zip file")
            exposure.mkdir()
            state = MODULE.ScanState(exposure)
            MODULE.inspect_zip(source, exposure / "1", "run:1/artifact:1/broken", state)
            self.assertEqual(state.incomplete[0]["reason"], "invalid-or-unreadable-zip")

    def test_inventory_rejects_missing_or_duplicate_items(self):
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_inventory([{"id": 1}], 2)
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_inventory([{"id": 1}, {"id": 1}], 2)
        MODULE.validate_inventory([{"id": 1}, {"id": 2}], 2)

    def test_artifact_snapshot_is_stable_and_excludes_expired_or_newer_items(self):
        selected, expired, newer = MODULE.select_artifacts_snapshot([
            {"id": 1, "created_at": "2026-11-27T04:00:00Z", "expired": False},
            {"id": 2, "created_at": "2026-11-27T03:00:00Z", "expired": True},
            {"id": 3, "created_at": "2026-11-27T05:01:00Z", "expired": False},
        ], "2026-11-27T05:00:00Z")
        self.assertEqual([item["id"] for item in selected], [1])
        self.assertEqual(expired, 1)
        self.assertEqual(newer, 1)

    def test_completed_run_snapshot_scans_old_completed_runs_only(self):
        selected, current, active, newer = MODULE.select_completed_runs_snapshot([
            {"id": 1, "created_at": "2026-11-27T04:00:00Z", "status": "completed"},
            {"id": 2, "created_at": "2026-11-27T04:30:00Z", "status": "in_progress"},
            {"id": 3, "created_at": "2026-11-27T05:01:00Z", "status": "completed"},
            {"id": 4, "created_at": "2026-11-27T04:45:00Z", "status": "in_progress"},
        ], "2026-11-27T05:00:00Z", 4)
        self.assertEqual([item["id"] for item in selected], [1])
        self.assertEqual(current, 1)
        self.assertEqual(active, 1)
        self.assertEqual(newer, 1)

    def test_completed_run_snapshot_fails_closed_on_invalid_timestamp(self):
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.select_completed_runs_snapshot(
                [{"id": 1, "status": "completed"}],
                "2026-11-27T05:00:00Z", 99,
            )

    def test_workflow_run_time_ranges_split_below_the_search_limit(self):
        start = datetime(2026, 1, 1, tzinfo=MODULE.timezone.utc)
        end = start + MODULE.timedelta(seconds=600)
        midpoint = start + MODULE.timedelta(seconds=300)

        def count_range(left, right):
            if left == start and right == end:
                return 1005
            if right <= midpoint:
                return 500
            if left > midpoint:
                return 505
            return 1005

        partitions = MODULE.partition_time_range(start, end, count_range)
        self.assertEqual(len(partitions), 2)
        self.assertEqual([item[2] for item in partitions], [500, 505])
        self.assertTrue(all(item[2] <= MODULE.MAX_RUNS_PER_SEARCH for item in partitions))
        self.assertEqual(partitions[0][1] + MODULE.timedelta(seconds=1), partitions[1][0])

    def test_workflow_run_partition_counts_must_reconcile_to_parent(self):
        start = datetime(2026, 1, 1, tzinfo=MODULE.timezone.utc)
        end = start + MODULE.timedelta(seconds=600)
        midpoint = start + MODULE.timedelta(seconds=300)

        def inconsistent_count(left, right):
            if left == start and right == end:
                return 1005
            if right <= midpoint:
                return 500
            if left > midpoint:
                return 504
            return 1005

        with self.assertRaisesRegex(
            MODULE.ForensicsError, "partition counts do not reconcile"
        ):
            MODULE.partition_time_range(start, end, inconsistent_count)

    def test_workflow_run_time_range_fails_when_single_second_exceeds_limit(self):
        start = datetime(2026, 1, 1, tzinfo=MODULE.timezone.utc)
        with self.assertRaisesRegex(MODULE.ForensicsError, "one-second timestamp"):
            MODULE.partition_time_range(
                start, start, lambda _left, _right: 1001
            )

    def test_current_workflow_run_id_is_parsed_and_validated(self):
        self.assertEqual(MODULE.parse_current_run_id(None), 0)
        self.assertEqual(MODULE.parse_current_run_id(""), 0)
        self.assertEqual(MODULE.parse_current_run_id("45943075360"), 45943075360)
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.parse_current_run_id("not-an-id")
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.parse_current_run_id("-1")

    def test_inventory_retry_recovers_from_transient_pagination_drift(self):
        attempts = {"count": 0}

        def flaky_inventory():
            attempts["count"] += 1
            if attempts["count"] < 3:
                raise MODULE.ForensicsError("total_count changed during workflow_runs pagination")
            return ([{"id": 7}], 1)

        with mock.patch.object(MODULE.time, "sleep") as sleep:
            result = MODULE.retry_inventory_call(flaky_inventory, attempts=4)

        self.assertEqual(result, ([{"id": 7}], 1))
        self.assertEqual(attempts["count"], 3)
        self.assertEqual(sleep.call_count, 2)

    def test_inventory_retry_does_not_hide_nontransient_failures(self):
        attempts = {"count": 0}

        def denied_inventory():
            attempts["count"] += 1
            raise MODULE.ForensicsError("inventory endpoint failed: http=403")

        with unittest.mock.patch.object(MODULE.time, "sleep") as sleep:
            with self.assertRaisesRegex(MODULE.ForensicsError, "http=403"):
                MODULE.retry_inventory_call(denied_inventory, attempts=4)

        self.assertEqual(attempts["count"], 1)
        sleep.assert_not_called()

    def test_repository_inventory_confirmation_rejects_concurrent_changes(self):
        original = [{"id": 10}, {"id": 11}]
        MODULE.validate_stable_inventory(original, [{"id": 11}, {"id": 10}])
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_stable_inventory(original, [{"id": 10}, {"id": 12}])
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_stable_inventory(original, [{"id": 10}])

    def test_artifact_snapshot_fails_closed_on_missing_or_invalid_timestamp(self):
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.select_artifacts_snapshot([{"id": 1, "expired": False}], "2026-11-27T05:00:00Z")
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.select_artifacts_snapshot(
                [{"id": 1, "created_at": "not-a-date", "expired": False}],
                "2026-11-27T05:00:00Z",
            )

    def test_gitleaks_exit_code_must_match_report(self):
        self.assertEqual(MODULE.validate_gitleaks_result(0, True, []), [])
        self.assertEqual(
            MODULE.validate_gitleaks_result(1, True, [{"RuleID": "test"}])[0]["RuleID"], "test"
        )
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_gitleaks_result(0, False, [])
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_gitleaks_result(0, True, [{"RuleID": "unexpected"}])
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_gitleaks_result(1, True, [])
        with self.assertRaises(MODULE.ForensicsError):
            MODULE.validate_gitleaks_result(2, True, [])


    def test_incremental_artifact_snapshot_selects_only_newer_nonexpired_items(self):
        selected, expired, old = MODULE.select_artifacts_after_cutoff([
            {"id": 1, "created_at": "2026-11-27T05:00:29Z", "expired": False},
            {"id": 2, "created_at": "2026-11-27T05:00:30Z", "expired": False},
            {"id": 3, "created_at": "2026-11-27T05:01:00Z", "expired": True},
            {"id": 4, "created_at": "2026-11-27T06:00:00Z", "expired": False},
        ], "2026-11-27T05:00:29Z")
        self.assertEqual([item["id"] for item in selected], [2, 4])
        self.assertEqual(expired, 1)
        self.assertEqual(old, 1)

    def test_incremental_workflow_run_snapshot_selects_completed_runs_after_cutoff(self):
        selected, current, noncompleted, old = MODULE.select_completed_runs_after_cutoff([
            {"id": 1, "created_at": "2026-11-27T05:00:29Z", "status": "completed"},
            {"id": 2, "created_at": "2026-11-27T05:00:30Z", "status": "completed"},
            {"id": 3, "created_at": "2026-11-27T05:01:00Z", "status": "in_progress"},
            {"id": 4, "created_at": "2026-11-27T05:02:00Z", "status": "completed"},
            {"id": 5, "created_at": "2026-11-27T05:03:00Z", "status": "completed"},
        ], "2026-11-27T05:00:29Z", 5)
        self.assertEqual([item["id"] for item in selected], [2, 4])
        self.assertEqual(current, 1)
        self.assertEqual([item["id"] for item in noncompleted], [3])
        self.assertEqual(old, 1)

    def test_workflow_run_partitioning_accepts_exclusive_lower_cutoff(self):
        start = datetime(2026, 11, 27, 5, 0, 29, tzinfo=MODULE.timezone.utc)
        end = start + MODULE.timedelta(seconds=20)
        observed = []
        def fake_partition(left, right, _provider):
            observed.append((left, right))
            return []
        with mock.patch.object(MODULE, "partition_time_range", side_effect=fake_partition):
            runs, total, partitions = MODULE.list_workflow_runs_partitioned(
                "https://api.github.com/repos/imo-foad/graduate_Project",
                end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                start_after=start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            )
        self.assertEqual((runs, total, partitions), ([], 0, 0))
        self.assertEqual(observed[0][0], start + MODULE.timedelta(seconds=1))


    def test_signed_artifact_download_retries_a_transient_redirect_failure(self):
        class FakeResponse(io.BytesIO):
            status = 200

        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "artifact.zip"
            with mock.patch.object(MODULE, "api_open", side_effect=[
                (None, 302, {"Location": "https://signed.example/first"}),
                (None, 302, {"Location": "https://signed.example/refreshed"}),
            ]) as api_call, mock.patch.object(
                MODULE.urllib.request,
                "urlopen",
                side_effect=[OSError("transient signed URL failure"), FakeResponse(b"PK\\x03\\x04test")],
            ) as signed_download, mock.patch.object(MODULE.time, "sleep"):
                ok, status, reason = MODULE.download_archive(
                    "https://api.github.com/repos/example/repo/actions/artifacts/1/zip",
                    destination,
                )
            self.assertTrue(ok)
            self.assertEqual(status, 200)
            self.assertEqual(reason, "downloaded")
            self.assertEqual(api_call.call_count, 2)
            self.assertEqual(signed_download.call_count, 2)
            self.assertTrue(destination.is_file())
            self.assertEqual(destination.read_bytes(), b"PK\\x03\\x04test")


    def test_run_log_404_is_skipped_only_when_github_confirms_zero_jobs(self):
        api = "https://api.github.com/repos/example/repo"
        with mock.patch.object(
            MODULE, "api_json", return_value=(200, {"total_count": 0, "jobs": []})
        ):
            self.assertTrue(MODULE.workflow_run_has_no_jobs(api, 46057935915))
        with mock.patch.object(
            MODULE, "api_json", return_value=(200, {"total_count": 2, "jobs": [{"id": 1}]})
        ):
            self.assertFalse(MODULE.workflow_run_has_no_jobs(api, 46057935915))
        with mock.patch.object(MODULE, "api_json", return_value=(403, None)):
            self.assertIsNone(MODULE.workflow_run_has_no_jobs(api, 46057935915))
        with mock.patch.object(MODULE, "api_json", return_value=(200, {"jobs": []})):
            self.assertIsNone(MODULE.workflow_run_has_no_jobs(api, 46057935915))

    def test_noncompleted_runs_are_deferred_without_becoming_incomplete(self):
        runs = [
            {"id": 21, "status": "completed", "name": "backend-tests",
             "created_at": "2026-11-27T19:00:00Z"},
            {"id": 22, "status": "in_progress", "name": "backend-tests",
             "created_at": "2026-11-27T19:01:00Z"},
            {"id": 23, "status": "queued", "name": "issue-44-public-secret-audit",
             "created_at": "2026-11-27T19:02:00Z"},
        ]
        state = MODULE.ScanState(Path("."))
        deferred = MODULE.deferred_run_records(runs, 22)
        self.assertEqual([item["run_id"] for item in deferred], [22, 23])
        self.assertTrue(deferred[0]["is_current_run"])
        self.assertFalse(deferred[1]["is_current_run"])
        self.assertEqual(state.incomplete, [])

    def test_finding_classification_requires_exact_rule_origin_member_and_line(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exposure = root / "extracted"
            exposure.mkdir()
            report = root / "classifications.json"
            report.write_text(json.dumps({
                "schema_version": 1,
                "classifications": [{
                    "rule_id": "supabase-secret-key",
                    "origin": "run:77/logs",
                    "member": "0_database.txt",
                    "line": 861,
                    "classification": "LOCAL_EPHEMERAL_SUPABASE_KEY",
                    "verdict": "LOCAL_EPHEMERAL_NOT_HOSTED",
                    "rationale": "The run used the disposable local Supabase stack.",
                    "baseline_occurrences": 1,
                }],
            }), encoding="utf-8")
            index = MODULE.load_finding_classifications(report)
            file_path = exposure / "database" / "0_database.txt"
            file_path.parent.mkdir()
            file_path.write_text("redacted fixture context only", encoding="utf-8")
            manifest = {
                file_path.relative_to(exposure).as_posix(): {
                    "origin": "run:77/logs", "member": "0_database.txt",
                }
            }
            finding = {
                "RuleID": "supabase-secret-key", "File": str(file_path), "StartLine": 861,
            }
            classified, unclassified = MODULE.classify_gitleaks_findings(
                [finding], exposure, manifest, index
            )
            self.assertEqual(unclassified, [])
            self.assertEqual(classified[0]["verdict"], "LOCAL_EPHEMERAL_NOT_HOSTED")
            self.assertEqual(classified[0]["observed_count"], 1)

            classified, unclassified = MODULE.classify_gitleaks_findings(
                [dict(finding, StartLine=862)], exposure, manifest, index
            )
            self.assertEqual(classified, [])
            self.assertEqual(len(unclassified), 1)

            wrong_origin = {
                file_path.relative_to(exposure).as_posix(): {
                    "origin": "run:78/logs", "member": "0_database.txt",
                }
            }
            classified, unclassified = MODULE.classify_gitleaks_findings(
                [finding], exposure, wrong_origin, index
            )
            self.assertEqual(classified, [])
            self.assertEqual(len(unclassified), 1)

    def test_duplicate_or_unsupported_finding_classifications_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "classifications.json"
            entry = {
                "rule_id": "generic-api-key", "origin": "run:1/logs",
                "member": "database.txt", "line": 10,
                "classification": "SYNTHETIC_LOCAL_TEST_DIAGNOSTIC",
                "verdict": "NON_SECRET_SYNTHETIC_TEST_DATA",
                "rationale": "Disposable local integration fixture metadata.",
            }
            path.write_text(json.dumps({
                "schema_version": 1, "classifications": [entry, entry],
            }), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ForensicsError, "duplicate source keys"):
                MODULE.load_finding_classifications(path)
            entry["verdict"] = "SUPPRESSED_ALL_GENERIC_API_KEYS"
            path.write_text(json.dumps({
                "schema_version": 1, "classifications": [entry],
            }), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ForensicsError, "invalid value"):
                MODULE.load_finding_classifications(path)

    def test_permanent_artifact_download_failure_remains_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "unavailable.zip"
            with mock.patch.object(MODULE, "api_open", return_value=(None, 403, {})), \
                 mock.patch.object(MODULE.time, "sleep") as sleep:
                ok, status, reason = MODULE.download_archive(
                    "https://api.github.com/repos/example/repo/actions/artifacts/404/zip",
                    destination,
                )
            self.assertFalse(ok)
            self.assertEqual(status, 403)
            self.assertEqual(reason, "artifact-download-unavailable")
            self.assertFalse(destination.exists())
            sleep.assert_not_called()

if __name__ == "__main__":
    unittest.main()
