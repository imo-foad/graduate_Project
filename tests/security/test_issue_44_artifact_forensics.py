"""Offline security tests for Issue #44 artifact forensics."""
import importlib.util
import io
import tempfile
import unittest
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
            extracted = list((exposure / "42" / "_quarantine").glob("*.bin"))
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
                "inner.zip!/nested/credential.txt" in item["origin"]
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
