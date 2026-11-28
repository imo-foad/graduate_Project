"""Static contract check: docs/openapi.yaml must match the REAL SQL grants/functions and the Edge Function.
Reads migrations as text (no database). Needs PyYAML. Run: python3 -m unittest tests/contract_openapi.py -v"""
import glob, json, os, re, unittest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), "..")
SQL = "\n".join(open(f).read() for f in sorted(glob.glob(os.path.join(ROOT, "supabase/migrations/*.sql"))))
API = yaml.safe_load(open(os.path.join(ROOT, "docs/openapi.yaml")))
EDGE_INDEX = open(os.path.join(ROOT, "supabase/functions/recommend/index.ts")).read()
FLOW = open(os.path.join(ROOT, "supabase/functions/_shared/recommend-flow.ts")).read()
EDGE = EDGE_INDEX + "\n" + FLOW  # the function = thin handler + orchestration module
CV_EDGE = open(os.path.join(ROOT, "supabase/functions/parse-cv/index.ts")).read()
CV_PARSER = open(os.path.join(ROOT, "supabase/functions/_shared/cv-file-parser.ts")).read()
INTERNAL_OK = {"is_opportunity_open", "is_opportunity_type_active"}  # scope predicates, never exposed as RPC endpoints
# Existing Admin onboarding RPCs from the base branch are intentionally outside this Scholarship issue.
# Their missing OpenAPI paths remain tracked with the onboarding work; do not silently change their behavior here.
PREEXISTING_UNDOCUMENTED_ADMIN_RPCS = {
    "list_graduate_invitations", "request_account_deletion", "review_account_deletion_request",
    "get_account_deletion_queue", "assert_platform_admin", "set_platform_admin_access",
    "transfer_company_creator",
}

# Historical applications are retained for audit/data integrity but are intentionally not part of
# the client API after product scope cancellation (migration 0025). Only service_role retains SELECT.
SERVICE_ROLE_ONLY_HISTORICAL_TABLES = {
    "scholarship_applications",
    "scholarship_application_status_history",
    "competition_applications",
    "competition_application_status_history",
}


def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(": depth += 1
        if ch == ")": depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip(): out.append(cur.strip())
    return out


def functions():
    fns = {}
    pat = r"create or replace function\s+public\.(\w+)\s*\((.*?)\)\s*returns[\s\S]*?(\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$)(.*?)\3"
    for m in re.finditer(pat, SQL, re.S | re.I):  # later definitions win
        params = []
        for p in split_top(m.group(2)):
            toks = p.split()
            params.append((toks[0], " default " in (" " + p.lower() + " ")))
        fns[m.group(1)] = {"params": params, "body": m.group(4)}
    return fns


def exec_granted(role):
    """Final EXECUTE state for a role: grants and revokes are applied in migration order."""
    names = set()
    for m in re.finditer(r"(?i)\b(grant|revoke)\s+(?:all|execute)\s+on\s+function\s+(.*?)\s+(?:to|from)\s+([^;]+);", SQL, re.S):
        action, fn_text, roles_text = m.group(1).lower(), m.group(2), m.group(3)
        if role not in [r.strip() for r in roles_text.split(",")]:
            continue
        found = set(re.findall(r"public\.(\w+)\(", fn_text))
        if action == "grant":
            names |= found
        else:
            names -= found
    return names


def table_grants(role="authenticated"):
    """Final table capabilities, preserving independent column-level grants/revokes."""
    table_level = {}
    column_level = {}
    for statement in re.finditer(r"(?im)^[ \t]*(grant|revoke)\b(.*?);", SQL, re.S):
        action, body = statement.group(1).lower(), statement.group(2)
        parsed = re.match(r"(?is)\s*(.+?)\s+on\s+(?!function\b)(.+?)\s+(?:to|from)\s+(.+?)\s*$", body)
        if not parsed:
            continue
        priv_text, object_text, roles_text = parsed.groups()
        if role not in [r.strip() for r in roles_text.split(",")]:
            continue
        if not object_text.strip().lower().startswith("public."):
            continue

        for table_item in split_top(object_text):
            table = table_item.replace("public.", "").strip()
            table_level.setdefault(table, set())
            column_level.setdefault(table, {})
            for item in split_top(priv_text):
                match = re.fullmatch(r"(?is)\s*([a-z_]+)(?:\s*\((.*)\))?\s*", item)
                if not match:
                    continue
                privilege, columns_text = match.groups()
                privilege = privilege.lower()
                if privilege == "all":
                    if columns_text is None:
                        if action == "grant":
                            # Preserve the legacy contract parser's distinction between an explicit
                            # HTTP method grant and GRANT ALL. The latter is not expanded into a
                            # fabricated REST surface; explicit method grants remain comparable.
                            table_level[table].add("all")
                        else:
                            table_level[table].clear()
                            column_level[table].clear()
                    continue

                if columns_text is not None:
                    columns = set(split_top(columns_text))
                    granted_columns = column_level[table].setdefault(privilege, set())
                    if action == "grant":
                        granted_columns.update(columns)
                    else:
                        granted_columns.difference_update(columns)
                elif action == "grant":
                    table_level[table].add(privilege)
                else:
                    table_level[table].discard(privilege)

    grants = {}
    for table, privs in table_level.items():
        effective = set(privs)
        effective.update(priv for priv, columns in column_level[table].items() if columns)
        grants[table] = effective
    return grants

METHOD_PRIV = {"get": "select", "post": "insert", "patch": "update", "delete": "delete"}


class Contract(unittest.TestCase):
    def test_rpc_paths_match_sql_signatures(self):
        fns, granted = functions(), exec_granted("authenticated")
        rpc = {p.rsplit("/", 1)[1]: v for p, v in API["paths"].items() if p.startswith("/rest/v1/rpc/")}
        self.assertTrue(rpc)
        for name, op in rpc.items():
            self.assertIn(name, fns, f"{name}: no such SQL function")
            self.assertIn(name, granted, f"{name}: not executable by authenticated")
            schema = op["post"].get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema", {})
            props, req = set(schema.get("properties", {})), set(schema.get("required", []))
            sql_params = {n for n, _ in fns[name]["params"]}
            sql_required = {n for n, has_default in fns[name]["params"] if not has_default}
            self.assertEqual(props, sql_params, f"{name}: parameter names differ")
            self.assertEqual(req, sql_required, f"{name}: required parameters differ")

    def test_every_client_callable_rpc_is_documented(self):
        documented = {p.rsplit("/", 1)[1] for p in API["paths"] if p.startswith("/rest/v1/rpc/")}
        self.assertEqual(
            exec_granted("authenticated") - INTERNAL_OK - PREEXISTING_UNDOCUMENTED_ADMIN_RPCS,
            documented - PREEXISTING_UNDOCUMENTED_ADMIN_RPCS,
        )

    def test_no_client_rpc_accepts_a_graduate_id(self):
        fns = functions()
        for name in exec_granted("authenticated") - INTERNAL_OK - PREEXISTING_UNDOCUMENTED_ADMIN_RPCS:
            for p, _ in fns[name]["params"]:
                self.assertNotIn("graduate", p, f"{name}({p}) lets the client choose the identity")

    def test_table_paths_never_promise_more_than_grants(self):
        grants = table_grants()
        for path, ops in API["paths"].items():
            if not path.startswith("/rest/v1/") or "/rpc/" in path: continue
            table = path.rsplit("/", 1)[1]
            self.assertIn(table, grants, f"{table}: documented but no grant to authenticated")
            for method in ops:
                self.assertIn(METHOD_PRIV[method], grants[table], f"{method.upper()} {path} not granted in SQL")

    def test_column_level_profile_revokes_preserve_other_supported_updates(self):
        grants = table_grants()
        self.assertIn("update", grants["profiles"],
                      "full_name remains writable after avatar_url is revoked")

    def test_cancelled_application_tables_remain_service_role_only(self):
        migration = open(os.path.join(ROOT, "supabase/migrations/0025_cancel_scholarship_and_competition.sql")).read()
        self.assertIn("revoke all on public.scholarship_applications", migration)
        self.assertIn("public.competition_applications", migration)
        self.assertIn("competition_application_status_history", migration)
        self.assertIn("to service_role", migration)
        self.assertIn("CANCELLED FEATURE", migration)

    def test_every_granted_table_capability_is_documented(self):
        for table, privs in table_grants().items():
            if table in SERVICE_ROLE_ONLY_HISTORICAL_TABLES:
                continue
            ops = API["paths"].get(f"/rest/v1/{table}")
            self.assertIsNotNone(ops, f"{table}: granted but undocumented")
            documented = {METHOD_PRIV[m] for m in ops}
            self.assertEqual(privs & set(METHOD_PRIV.values()), documented, f"{table}: grants {privs} vs docs {documented}")

    def test_error_codes_in_sql_are_documented(self):
        fns = functions()
        text = API["components"]["responses"]["BusinessError"]["description"]
        codes = set()
        for name in exec_granted("authenticated") - INTERNAL_OK - PREEXISTING_UNDOCUMENTED_ADMIN_RPCS:
            codes |= set(re.findall(r"raise exception '([A-Z_]+)'", fns[name]["body"]))
        codes |= set(re.findall(r"raise exception '([A-Z_]+)'", fns["_require_uid"]["body"]))
        for c in sorted(codes):
            self.assertIn(c, text, f"error code {c} raised by SQL but not in contract")

    def test_documented_error_codes_exist_in_sql(self):
        text = API["components"]["responses"]["BusinessError"]["description"]
        documented = set(re.findall(r"\b[A-Z]{3,}(?:_[A-Z]+)+\b|\bUNAUTHENTICATED\b", text))
        raised = set(re.findall(r"raise exception '([A-Z_]+)'", SQL))
        self.assertFalse(documented - raised, f"documented but never raised: {documented - raised}")

    def test_parse_cv_function_contract(self):
        op = API["paths"]["/functions/v1/parse-cv"]["post"]
        schema = op["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(set(schema["required"]), {"cv_document_id"})
        self.assertEqual(set(schema["properties"]), {"cv_document_id"})
        self.assertIs(schema["additionalProperties"], False)
        self.assertTrue({"200", "400", "401", "404", "405", "409", "413", "422", "500", "502"} <= set(op["responses"]))
        for needle in ("auth.getUser()", 'from("cv_documents")', 'from("cv-documents")',
                       'rpc("complete_cv_parse"', 'from("skills")', "confirmation_required"):
            self.assertIn(needle, CV_EDGE)
        for needle in ("extractDocxText", "extractPdfText", "MAX_FILE_BYTES", "MAX_PDF_PAGES"):
            self.assertIn(needle, CV_PARSER)
        self.assertNotIn('admin.from("graduate_skills")', CV_EDGE)
        self.assertIn("confirm_cv_suggestions", open(os.path.join(ROOT, "docs/ANDROID_INTEGRATION.md")).read())

    def test_recommend_function_contract(self):
        resp = API["paths"]["/functions/v1/recommend"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]["properties"]
        for key in ("source", "model_version", "ai_mode", "disclaimer", "items"):
            self.assertIn(key, resp)
            self.assertRegex(EDGE, rf"\b{key}\b", f"{key} not produced by the Edge Function")
        self.assertIn("opportunity", API["components"]["schemas"]["Recommendation"]["properties"])
        self.assertIn("opportunity:opportunities(", EDGE)
        self.assertIn("career_profile", resp)
        self.assertIn("deriveCareerProfile", EDGE)
        self.assertIn('neq("model_version", MODEL_VERSION)', EDGE_INDEX)
        self.assertIn("PROFILE_SKILLS_READ_FAILED", EDGE_INDEX)

    def test_career_profile_response_contract(self):
        schemas = API["components"]["schemas"]
        profile = schemas["CareerProfile"]
        self.assertEqual(set(profile["required"]), {"primary_path", "paths", "disclaimer"})
        path_schema = schemas["CareerPathMatch"]
        self.assertTrue({
            "id", "label", "score", "matched_skill_ids", "matched_core_skill_ids",
            "matched_supporting_skill_ids", "specialization_signal_skill_ids",
            "missing_core_skill_ids", "next_skill_ids",
            "core_match_count", "required_core_match_count", "skill_evidence", "explanation_ar",
        } <= set(path_schema["properties"]))
        self.assertIn("$ref", profile["properties"]["paths"]["items"])
        self.assertIn("career_profile", EDGE)

    def test_cancelled_features_are_absent_from_the_api_contract(self):
        # Product decision: Scholarship (#14) and Competition (#15) are cancelled, so no endpoint,
        # schema, Edge Function or opportunity type may still be advertised.
        cancelled_paths = {
            "/functions/v1/submit-scholarship", "/functions/v1/deliver-scholarship",
            "/functions/v1/get-scholarship-review-cv", "/functions/v1/scholarship-provider-callback",
            "/rest/v1/rpc/apply_for_scholarship", "/rest/v1/rpc/withdraw_scholarship_application",
            "/rest/v1/rpc/apply_for_competition", "/rest/v1/rpc/withdraw_competition_application",
            "/rest/v1/rpc/create_admin_scholarship", "/rest/v1/rpc/update_admin_scholarship",
            "/rest/v1/rpc/publish_admin_scholarship", "/rest/v1/rpc/close_admin_scholarship",
            "/rest/v1/rpc/list_admin_scholarship_applications", "/rest/v1/rpc/get_admin_scholarship_application",
            "/rest/v1/rpc/review_scholarship_application", "/rest/v1/rpc/configure_scholarship_provider_mapping",
            "/rest/v1/rpc/set_scholarship_reviewer", "/rest/v1/rpc/get_scholarship_review_queue",
            "/rest/v1/rpc/retry_scholarship_delivery", "/rest/v1/rpc/assert_scholarship_admin",
            "/rest/v1/rpc/get_scholarship_review_cv_path",
            "/rest/v1/scholarship_applications", "/rest/v1/scholarship_application_status_history",
            "/rest/v1/competition_applications", "/rest/v1/competition_application_status_history",
        }
        self.assertEqual(cancelled_paths & set(API["paths"]), set())
        cancelled_schemas = {"AdminScholarshipOpportunity", "AdminScholarshipApplicationDetails",
                             "ScholarshipApplication", "ScholarshipApplicationHistory",
                             "CompetitionApplication", "CompetitionApplicationHistory"}
        self.assertEqual(cancelled_schemas & set(API["components"]["schemas"]), set())
        blob = json.dumps(API)
        for token in ('"SCHOLARSHIP"', '"COMPETITION"', "SCHOLARSHIP_", "COMPETITION_"):
            self.assertNotIn(token, blob, f"cancelled scope still advertised: {token}")
        for name in ("submit-scholarship", "deliver-scholarship", "get-scholarship-review-cv",
                     "scholarship-provider-callback"):
            self.assertFalse(os.path.exists(os.path.join(ROOT, "supabase/functions", name)), name)
        self.assertIn("is_opportunity_type_active", SQL)
        self.assertIn("CANCELLED_OPPORTUNITY_TYPE", SQL)

    def test_active_opportunity_scope_is_identical_in_sql_typescript_seed_and_openapi(self):
        # One allow-list, four representations. A drift here is the exact class of bug this contract guards.
        expected = ["JOB", "INTERNSHIP", "TRAINING"]

        sql_predicate = re.findall(
            r"function public\.is_opportunity_type_active\(p_type text\)[\s\S]*?p_type in \(([^)]*)\)",
            SQL, re.I,
        )
        self.assertTrue(sql_predicate, "is_opportunity_type_active(p_type) must define an allow-list")
        sql_types = re.findall(r"'([A-Z_]+)'", sql_predicate[-1])
        self.assertEqual(sql_types, expected, "SQL active types drifted")

        ts = open(os.path.join(ROOT, "supabase/functions/_shared/opportunity-state.ts")).read()
        ts_list = re.search(r"ACTIVE_OPPORTUNITY_TYPES[^=]*=\s*\[([^\]]*)\]", ts)
        self.assertIsNotNone(ts_list)
        self.assertEqual(re.findall(r'"([A-Z_]+)"', ts_list.group(1)), expected, "TypeScript active types drifted")

        api_types = API["components"]["schemas"]["OpportunityType"]["enum"]
        self.assertEqual(api_types, expected, "OpenAPI active types drifted")

        seed = json.load(open(os.path.join(ROOT, "fixtures/opportunities.json")))
        seeded = sorted({item["type"] for item in seed})
        self.assertEqual(seeded, sorted(expected), "seed catalogue ships a non-active opportunity type")

        # Nothing in the API contract may advertise an inactive type value.
        blob = json.dumps(API)
        for token in ("EVENT", "CONFERENCE", "VOLUNTEER"):
            self.assertNotRegex(blob, rf'"{token}"', f"inactive type advertised: {token}")

    def test_social_feed_read_models_match_privacy_projection(self):
        schemas = API["components"]["schemas"]
        self.assertNotIn("author_id", schemas["SocialFeedItem"]["properties"])
        self.assertNotIn("author_id", schemas["SocialComment"]["properties"])
        self.assertIn("author_id", schemas["SocialCommentMutation"]["properties"])

        feed_item = API["paths"]["/rest/v1/rpc/get_social_feed"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]["items"]
        comment_item = API["paths"]["/rest/v1/rpc/get_social_post_comments"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]["items"]
        self.assertEqual(feed_item["$ref"], "#/components/schemas/SocialFeedItem")
        self.assertEqual(comment_item["$ref"], "#/components/schemas/SocialComment")

        for name in ("get_social_feed", "get_social_post_comments"):
            match = re.search(
                rf"create or replace function public\.{name}\([^)]*\)\s*returns table\s*\((.*?)\)\s*language",
                SQL, re.S | re.I,
            )
            self.assertIsNotNone(match, name)
            self.assertNotIn("author_id", match.group(1).lower(), name)

        for path in ("/rest/v1/rpc/add_social_comment", "/rest/v1/rpc/update_social_comment"):
            schema = API["paths"][path]["post"]["responses"]["200"]["content"]["application/json"]["schema"]
            self.assertEqual(schema["$ref"], "#/components/schemas/SocialCommentMutation")

    def test_refs_resolve_and_paths_have_methods(self):
        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k == "$ref":
                        cur = API
                        for part in v.lstrip("#/").split("/"): cur = cur[part]
                    else: walk(v)
            elif isinstance(node, list):
                for v in node: walk(v)
        walk(API)
        for path, ops in API["paths"].items():
            self.assertNotIn("?", path, f"{path}: query string in path key is invalid OpenAPI")
            self.assertTrue(ops)


class SecurityAndAuthContract(unittest.TestCase):
    TOKEN = "/auth/v1/token"

    def test_security_schemes(self):
        ss = API["components"]["securitySchemes"]
        self.assertEqual({k: ss["apiKeyAuth"][k] for k in ("type", "in", "name")}, {"type": "apiKey", "in": "header", "name": "apikey"})
        self.assertEqual((ss["jwt"]["type"], ss["jwt"]["scheme"]), ("http", "bearer"))

    def test_global_security_requires_both_headers(self):
        self.assertEqual(API["security"], [{"apiKeyAuth": [], "jwt": []}])

    def test_token_endpoint_needs_apikey_but_no_jwt(self):
        self.assertEqual(API["paths"][self.TOKEN]["post"]["security"], [{"apiKeyAuth": []}])

    def test_authenticated_operations_inherit_global_security(self):
        for path, ops in API["paths"].items():
            if path in (self.TOKEN, "/auth/v1/verify", "/functions/v1/register"): continue
            for method, op in ops.items():
                self.assertNotIn("security", op, f"{method.upper()} {path} overrides global security")

    def test_public_registration_still_requires_project_api_key(self):
        self.assertEqual(API["paths"]["/functions/v1/register"]["post"]["security"], [{"apiKeyAuth": []}])
        self.assertEqual(API["paths"]["/functions/v1/finalize-registration"]["post"].get("security"), None)

    def test_grant_types_and_bodies(self):
        op = API["paths"][self.TOKEN]["post"]
        param = next(p for p in op["parameters"] if p["name"] == "grant_type")
        self.assertEqual((param["in"], param["required"], set(param["schema"]["enum"])), ("query", True, {"password", "refresh_token"}))
        refs = [r["$ref"].rsplit("/", 1)[1] for r in op["requestBody"]["content"]["application/json"]["schema"]["oneOf"]]
        self.assertEqual(sorted(refs), ["PasswordGrantRequest", "RefreshTokenGrantRequest"])
        sch = API["components"]["schemas"]
        pw, rf = sch["PasswordGrantRequest"], sch["RefreshTokenGrantRequest"]
        self.assertEqual(set(pw["required"]), {"password"})
        self.assertEqual({frozenset(option["required"]) for option in pw["oneOf"]},
                         {frozenset({"email"}), frozenset({"phone"})})
        self.assertEqual(set(pw["properties"]), {"email", "phone", "password"})
        self.assertEqual(set(rf["required"]), {"refresh_token"})
        for s in (pw, rf): self.assertIs(s["additionalProperties"], False)
        self.assertFalse(set(pw["properties"]) & set(rf["properties"]), "bodies must be mutually exclusive")

    def test_token_responses(self):
        r = API["paths"][self.TOKEN]["post"]["responses"]
        self.assertTrue({"200", "400", "401"} <= set(r))
        tok = API["components"]["schemas"]["TokenResponse"]
        self.assertTrue({"access_token", "refresh_token", "expires_in"} <= set(tok["required"]))

    def test_no_nonexistent_operations_documented(self):
        for path in API["paths"]:
            if path == self.TOKEN or path.startswith("/rest/v1/"): continue
            self.assertTrue(path.startswith("/functions/v1/"), f"unexpected path {path}")
            fn = path.rsplit("/", 1)[1]
            self.assertTrue(os.path.exists(os.path.join(ROOT, "supabase/functions", fn, "index.ts")), f"{path}: no such Edge Function")

    def test_recommend_documents_its_real_error_responses(self):
        r = API["paths"]["/functions/v1/recommend"]["post"]["responses"]
        self.assertTrue({"200", "401", "409", "500"} <= set(r))
        flow = FLOW
        for code in API["components"]["schemas"]["RecommendError"]["properties"]["error"]["enum"]:
            if code in ("UNAUTHENTICATED", "METHOD_NOT_ALLOWED"): self.assertIn(code, EDGE)
            else: self.assertIn(code, flow + EDGE, f"{code} documented but never produced")

    def test_android_doc_matches_contract(self):
        doc = open(os.path.join(ROOT, "docs/ANDROID_INTEGRATION.md")).read()
        for needle in ("apikey", "grant_type=password", "grant_type=refresh_token", '"refresh_token"', "STALE_SNAPSHOT"):
            self.assertIn(needle, doc)
        refresh_block = doc.split("grant_type=refresh_token", 1)[1].split("```", 1)[0]
        self.assertNotIn("password", refresh_block, "refresh example must not send email/password")
        for name in re.findall(r"rpc/(\w+)", doc): self.assertIn(f"/rest/v1/rpc/{name}", API["paths"])
        for name in re.findall(r"/rest/v1/(?!rpc/)(\w+)", doc): self.assertIn(f"/rest/v1/{name}", API["paths"])
        for name in re.findall(r"/functions/v1/([\w-]+)", doc): self.assertIn(f"/functions/v1/{name}", API["paths"])
        self.assertIn("/auth/v1/token", doc)


if __name__ == "__main__":
    unittest.main()
