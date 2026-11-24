"""Static policy checks for the CI workflow and DB scripts (no GitHub needed). Run: python3 -m unittest tests/workflow_lint.py -v"""
import os, re, unittest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), "..")
def code(text):
    """Drop full-line and trailing comments so warnings written in comments are not mistaken for commands."""
    return "\n".join(re.sub(r"\s#\s.*$", "", l) for l in text.splitlines() if not l.lstrip().startswith("#"))


WF_TEXT = code(open(os.path.join(ROOT, ".github/workflows/backend-tests.yml")).read())
WF = yaml.safe_load(WF_TEXT)
SCRIPTS = {p: code(open(os.path.join(ROOT, p)).read()) for p in ("scripts/run-db-tests.sh", "tests/db/concurrency.sh")}


def steps(job): return WF["jobs"][job]["steps"]
def runs(job): return "\n".join(s.get("run", "") for s in steps(job))
def uses(job): return [s.get("uses", "") for s in steps(job)]


class Workflow(unittest.TestCase):
    def test_least_privilege(self):
        self.assertEqual(WF["permissions"], {"contents": "read"})
        for j, body in WF["jobs"].items():
            self.assertNotIn("permissions", body, f"{j} must not widen permissions")

    def test_jobs_have_timeouts(self):
        for j, body in WF["jobs"].items(): self.assertIsInstance(body.get("timeout-minutes"), int, j)

    def test_existing_jobs_preserved(self):
        self.assertTrue({"static", "database"} <= set(WF["jobs"]))
        r = runs("static")
        for needle in ("npm test", "tests/contract_openapi.py"): self.assertIn(needle, r)

    def test_database_job_prepares_and_runs_real_tests(self):
        r = runs("database")
        for needle in ("docker info", "postgresql-client", "psql --version", "supabase --version", "bash scripts/run-db-tests.sh"):
            self.assertIn(needle, r)
        self.assertTrue(any(u.startswith("supabase/setup-cli@") for u in uses("database")))

    def test_database_job_cannot_be_silenced(self):
        main = [s for s in steps("database") if "run-db-tests.sh" in s.get("run", "")]
        self.assertEqual(len(main), 1)
        self.assertNotIn("continue-on-error", main[0]); self.assertNotIn("|| true", main[0]["run"])
        self.assertNotIn("continue-on-error", WF["jobs"]["database"])

    def test_cleanup_and_diagnostics_always_run(self):
        for s in steps("database"):
            if "supabase stop" in s.get("run", "") or str(s.get("uses", "")).startswith("actions/upload-artifact"):
                self.assertEqual(s.get("if"), "always()")

    def test_no_cloud_access_anywhere(self):
        forbidden = ["supabase link", "db push", "SUPABASE_ACCESS_TOKEN", "SUPABASE_DB_PASSWORD", "qikqbvohqjblbcysbvel", "secrets.", "functions deploy"]
        blob = WF_TEXT + "".join(SCRIPTS.values())
        for f in forbidden: self.assertNotIn(f, blob, f"forbidden reference: {f}")


class Scripts(unittest.TestCase):
    def test_guard_runs_before_any_other_tool(self):
        for p, s in SCRIPTS.items():
            guard = s.index("assert-local-db.mjs")
            for tool in ("supabase start", "supabase db reset", "psql \"$DB_URL\"", "docker "):
                first = s.find(tool)
                if first != -1:
                    self.assertLess(guard, first, f"{p}: {tool} appears before the DB_URL guard")

    def test_no_substring_host_check_left(self):
        for p, s in SCRIPTS.items(): self.assertNotRegex(s, r"\*127\.0\.0\.1\*|\*localhost\*", p)

    def test_run_script_covers_all_phases_and_migrations(self):
        s = SCRIPTS["scripts/run-db-tests.sh"]
        for needle in ("supabase start", "supabase db reset", "build:seed", "supabase test db", "concurrency.sh", "schema_migrations",
                       "01_register_for_event", "05_recommendation_cache", "set -euo pipefail"):
            self.assertIn(needle, s)
        self.assertNotRegex(s, r"0001\.\.0006")
        migs = sorted(f for f in os.listdir(os.path.join(ROOT, "supabase/migrations")) if f.endswith(".sql"))
        self.assertEqual(len(migs), 8)
        self.assertEqual([m[:4] for m in migs], ["0001", "0002", "0003", "0004", "0005", "0006", "0007", "0008"])

    def test_all_pgtap_files_are_expected_by_the_runner(self):
        on_disk = sorted(f[:-len(".test.sql")] for f in os.listdir(os.path.join(ROOT, "supabase/tests/database")) if f.endswith(".test.sql"))
        s = SCRIPTS["scripts/run-db-tests.sh"]
        listed = re.search(r"EXPECTED_TESTS=\((.*?)\)", s).group(1).split()
        self.assertEqual(sorted(listed), on_disk, "a test file exists that the runner would not require (or vice versa)")


if __name__ == "__main__":
    unittest.main()
