"""Offline security tests for Issue #44 artifact forensics."""
import importlib.util
import io
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

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

if __name__ == "__main__":
    unittest.main()
