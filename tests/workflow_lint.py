"""Static policy checks for the CI workflow and DB scripts (no GitHub needed). Run: python3 -m unittest tests/workflow_lint.py -v"""
import os, re, unittest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), "..")
def code(text):
    """Drop full-line and trailing comments so warnings written in comments are not mistaken for commands."""
    return "\n".join(re.sub(r"\s#\s.*$", "", l) for l in text.splitlines() if not l.lstrip().startswith("#"))


WF_TEXT = code(open(os.path.join(ROOT, ".github/workflows/backend-tests.yml")).read())
WF = yaml.safe_load(WF_TEXT)
SCRIPTS = {p: code(open(os.path.join(ROOT, p)).read()) for p in ("scripts/run-db-tests.sh", "scripts/run-local-integrations.sh", "tests/db/concurrency.sh")}


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
        for needle in ("npm test", "tests/contract_openapi.py", "bash -n scripts/run-db-tests.sh scripts/run-local-integrations.sh tests/db/concurrency.sh", "node --check tests/integration/local-supabase.integration.mjs", "node --check tests/integration/cv-parse.integration.mjs", "node --check tests/integration/career-cohort.integration.mjs", "node --check tests/integration/onboarding.integration.mjs", "node --check tests/integration/rate-limits.integration.mjs"): self.assertIn(needle, r)

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
        stop = next(s for s in steps("database") if "supabase stop" in s.get("run", ""))
        self.assertIn("timeout 120s", stop["run"])

    def test_social_feed_like_race_is_in_concurrency_suite(self):
        concurrency = SCRIPTS["tests/db/concurrency.sh"]
        self.assertIn("public.like_social_post", concurrency)
        self.assertIn("social_post_likes", concurrency)
        self.assertIn("ALREADY_LIKED", concurrency)
        self.assertIn("N-1", concurrency)


    def test_cancelled_scope_guard_is_in_concurrency_suite(self):
        concurrency = SCRIPTS["tests/db/concurrency.sh"]
        self.assertIn("CANCELLED_OPPORTUNITY_TYPE", concurrency)
        self.assertIn("cancelled-race-", concurrency)
        # The cancelled provider-callback race must not be exercised any more.
        self.assertNotIn("process_scholarship_provider_event", concurrency)
        self.assertNotIn("scholarship_provider_events", concurrency)

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
        for needle in ("supabase start", "supabase db reset", "build:seed", "supabase test db", "concurrency.sh", "run-local-integrations.sh", "schema_migrations",
                       "01_register_for_event", "05_recommendation_cache", "06_company_workflow", "07_admin_company_controls", "08_cv_parse_lifecycle", "09_cv_intelligence", "10_cancelled_scope_guard", "12_social_feed", "13_social_moderation_rate_limits", "14_secure_graduate_onboarding", "15_three_type_scope", "16_cv_cleanup_queue", "17_recommendation_availability", "18_identity_and_organizations", "set -euo pipefail"):
            self.assertIn(needle, s)
        self.assertNotRegex(s, r"0001\.\.0006")
        migs = sorted(f for f in os.listdir(os.path.join(ROOT, "supabase/migrations")) if f.endswith(".sql"))
        self.assertEqual(len(migs), 27)
        self.assertEqual([m[:4] for m in migs], ["0001", "0002", "0003", "0004", "0005", "0006", "0007", "0008", "0009", "0010", "0011", "0012", "0013", "0014", "0015", "0016", "0017", "0018", "0019", "0020", "0021", "0023", "0024", "0025", "0026", "0027", "0028"])

    def test_local_http_stage_covers_auth_storage_and_edge_function(self):
        runner = SCRIPTS["scripts/run-local-integrations.sh"]
        http = code(open(os.path.join(ROOT, "tests/integration/local-supabase.integration.mjs")).read())
        cv_http = code(open(os.path.join(ROOT, "tests/integration/cv-parse.integration.mjs")).read())
        for needle in ("provision-demo-users.mjs", "03_demo_profiles.sql", "supabase functions serve",
                       "api.url=SUPABASE_URL", "auth.anon_key=SUPABASE_ANON_KEY",
                       "auth.service_role_key=SUPABASE_SERVICE_ROLE_KEY", "DEMO_PASSWORD", "assert-local-db.mjs"):
            self.assertIn(needle, runner)
        for needle in ("/auth/v1/token", "/storage/v1/object/", "/rest/v1/cv_documents",
                       "/functions/v1/recommend", "force: true", "cv-documents",
                       "/functions/v1/${name}", "cancelled Edge Function ${name} is not deployed",
                       "/rest/v1/rpc/apply_for_scholarship", "/rest/v1/rpc/apply_for_competition",
                       "cancelled opportunity types are absent from catalogue discovery",
                        "/rest/v1/rpc/get_social_feed", "/rest/v1/rpc/create_social_post", "/rest/v1/rpc/update_social_post",
                        "/rest/v1/rpc/delete_social_post", "/rest/v1/rpc/get_social_post_comments", "/rest/v1/rpc/add_social_comment",
                        "/rest/v1/rpc/update_social_comment", "/rest/v1/rpc/delete_social_comment", "/rest/v1/rpc/like_social_post",
                        "/rest/v1/rpc/unlike_social_post", "SOCIAL_POST_NOT_FOUND", "ALREADY_LIKED"):
            self.assertIn(needle, http)
        for needle in ("/functions/v1/parse-cv", "/functions/v1/recommend", "confirm_cv_suggestions", "CV_NO_TEXT_FOUND", "CV_ALREADY_PARSED",
                       "graduate_skills", "cv_suggestions", "Python, Machine Learning, Statistics", "Data Analyst", "score_breakdown", "current_level", "review_cv_suggestions", "get_career_market_insights", "record_recommendation_interaction", "Advanced TypeScript"):
            self.assertIn(needle, cv_http)
        self.assertIn("cv-parse.integration.mjs", runner)
        self.assertIn("onboarding.integration.mjs", runner)
        self.assertIn("rate-limits.integration.mjs", runner)
        onboarding_http = code(open(os.path.join(ROOT, "tests/integration/onboarding.integration.mjs")).read())
        rate_http = code(open(os.path.join(ROOT, "tests/integration/rate-limits.integration.mjs")).read())
        self.assertIn("ONBOARDING HTTP INTEGRATION PASSED", onboarding_http)
        self.assertIn("RATE-LIMIT HTTP INTEGRATION PASSED", rate_http)
        self.assertIn("/functions/v1/invite-graduate", onboarding_http)
        self.assertIn("bootstrap-platform-admin.mjs", onboarding_http)  # first-admin bootstrap moved here
        self.assertIn("assert_platform_admin", onboarding_http)
        self.assertIn("/functions/v1/parse-cv", rate_http)
        self.assertIn("career-cohort.integration.mjs round1", runner)
        self.assertIn("career-cohort.integration.mjs round2", runner)
        self.assertIn('[ "$CODE" = "405" ]', runner)
        self.assertIn("READY_STREAK=0", runner)
        self.assertIn('[ "$READY_STREAK" -ge 2 ]', runner)
        self.assertIn('"$LOG_DIR/functions-serve.log"', runner)
        self.assertIn("expected two consecutive HTTP 405 GET responses", runner)
        self.assertIn("MAX_FUNCTION_METHOD_RETRIES = 10", http)
        self.assertIn("attempt < MAX_FUNCTION_METHOD_RETRIES", http)
        self.assertIn("Retrying recommend method guard", http)
        self.assertIn("timeout 900s", runner)
        self.assertIn("career-cohort-reports/", WF_TEXT)
        self.assertIn("name: career-cohort-reports", WF_TEXT)
        self.assertIn("bash scripts/run-local-integrations.sh", SCRIPTS["scripts/run-db-tests.sh"])

    def test_all_pgtap_files_are_expected_by_the_runner(self):
        on_disk = sorted(f[:-len(".test.sql")] for f in os.listdir(os.path.join(ROOT, "supabase/tests/database")) if f.endswith(".test.sql"))
        s = SCRIPTS["scripts/run-db-tests.sh"]
        listed = re.search(r"EXPECTED_TESTS=\((.*?)\)", s).group(1).split()
        self.assertEqual(sorted(listed), on_disk, "a test file exists that the runner would not require (or vice versa)")


if __name__ == "__main__":
    unittest.main()
