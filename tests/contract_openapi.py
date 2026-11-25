"""Static contract check: docs/openapi.yaml must match the REAL SQL grants/functions and the Edge Function.
Reads migrations as text (no database). Needs PyYAML. Run: python3 -m unittest tests/contract_openapi.py -v"""
import glob, os, re, unittest
import yaml

ROOT = os.path.join(os.path.dirname(__file__), "..")
SQL = "\n".join(open(f).read() for f in sorted(glob.glob(os.path.join(ROOT, "supabase/migrations/*.sql"))))
API = yaml.safe_load(open(os.path.join(ROOT, "docs/openapi.yaml")))
EDGE_INDEX = open(os.path.join(ROOT, "supabase/functions/recommend/index.ts")).read()
FLOW = open(os.path.join(ROOT, "supabase/functions/_shared/recommend-flow.ts")).read()
EDGE = EDGE_INDEX + "\n" + FLOW  # the function = thin handler + orchestration module
CV_EDGE = open(os.path.join(ROOT, "supabase/functions/parse-cv/index.ts")).read()
CV_PARSER = open(os.path.join(ROOT, "supabase/functions/_shared/cv-file-parser.ts")).read()
INTERNAL_OK = {"is_opportunity_open"}  # helper is private-schema only and must never be exposed as a public RPC
# Existing Admin onboarding RPCs from the base branch are intentionally outside this Scholarship issue.
# Their missing OpenAPI paths remain tracked with the onboarding work; do not silently change their behavior here.
PREEXISTING_UNDOCUMENTED_ADMIN_RPCS = {
    "list_graduate_invitations", "request_account_deletion", "review_account_deletion_request",
    "get_account_deletion_queue", "assert_platform_admin", "set_platform_admin_access",
    "transfer_company_creator",
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
    names = set()
    for m in re.finditer(r"grant execute on function\s+(.*?)\s+to\s+([^;]+);", SQL, re.S | re.I):
        if role in [r.strip() for r in m.group(2).split(",")]:
            names |= set(re.findall(r"public\.(\w+)\(", m.group(1)))
    return names


def table_grants(role="authenticated"):
    grants = {}
    for statement in re.finditer(r"(?im)^[ \t]*grant\b(.*?);", SQL, re.S):
        parsed = re.match(r"(?is)\s*(.+?)\s+on\s+(?!function\b)(.+?)\s+to\s+(.+?)\s*$", statement.group(1))
        if not parsed: continue
        priv_text, object_text, roles_text = parsed.groups()
        if role not in [r.strip() for r in roles_text.split(",")]: continue
        privs = {re.match(r"\w+", p).group(0).lower() for p in split_top(priv_text)}
        if not object_text.strip().lower().startswith("public."):
            continue
        for t in split_top(object_text):
            grants.setdefault(t.replace("public.", "").strip(), set()).update(privs)
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
        self.assertEqual(exec_granted("authenticated") - INTERNAL_OK - PREEXISTING_UNDOCUMENTED_ADMIN_RPCS, documented)

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

    def test_every_granted_table_capability_is_documented(self):
        for table, privs in table_grants().items():
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

    def test_scholarship_delivery_and_review_contract(self):
        submit = API["paths"]["/functions/v1/submit-scholarship"]["post"]
        schema = submit["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(set(schema["required"]), {"p_opportunity_id"})
        self.assertEqual(
            set(schema["properties"]),
            {"p_opportunity_id", "p_cv_document_id", "p_personal_statement", "p_application_data"},
        )
        self.assertIs(schema["additionalProperties"], False)
        self.assertTrue({"200", "202", "400", "401", "409", "422"} <= set(submit["responses"]))

        sample_schema = API["components"]["schemas"]["ScholarshipApplication"]["properties"]
        self.assertIn("PENDING_DELIVERY", sample_schema["status"]["enum"])
        self.assertIn("SUBMITTED_EXTERNALLY", sample_schema["status"]["enum"])
        self.assertIn("INTERNAL_ONLY", sample_schema["status"]["enum"])
        self.assertIn("delivery_status", sample_schema)

        delivery = API["paths"]["/functions/v1/deliver-scholarship"]["post"]
        self.assertTrue({"200", "400", "401", "403", "503"} <= set(delivery["responses"]))
        reviewer_cv = API["paths"]["/functions/v1/get-scholarship-review-cv"]["post"]
        reviewer_cv_schema = reviewer_cv["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(set(reviewer_cv_schema["required"]), {"application_id"})
        self.assertTrue({"200", "400", "401", "403", "404", "409", "503"} <= set(reviewer_cv["responses"]))
        reviewer_rpc_schema = API["paths"]["/rest/v1/rpc/get_scholarship_review_cv_path"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(set(reviewer_rpc_schema["required"]), {"p_application_id"})
        callback = API["paths"]["/functions/v1/scholarship-provider-callback"]["post"]
        self.assertEqual(callback["security"], [])
        self.assertIn("X-Alumni-Timestamp", [p["name"] for p in callback["parameters"]])
        self.assertIn("X-Alumni-Signature", [p["name"] for p in callback["parameters"]])
        callback_schema = callback["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(set(callback_schema["required"]),
            {"provider_key", "event_id", "application_reference", "status"})
        self.assertIs(callback_schema["additionalProperties"], False)

        from pathlib import Path
        root = Path(ROOT)
        submit_edge = (root / "supabase/functions/submit-scholarship/index.ts").read_text()
        delivery_edge = (root / "supabase/functions/deliver-scholarship/index.ts").read_text()
        callback_edge = (root / "supabase/functions/scholarship-provider-callback/index.ts").read_text()
        reviewer_cv_edge = (root / "supabase/functions/get-scholarship-review-cv/index.ts").read_text()
        provider = (root / "supabase/functions/_shared/scholarship-provider.ts").read_text()
        self.assertIn('auth.getUser()', submit_edge)
        self.assertRegex(submit_edge, r'rpc\(\s*"apply_for_scholarship"')
        self.assertIn("INTERNAL_ONLY", submit_edge)
        self.assertIn('rpc("assert_scholarship_admin"', delivery_edge)
        self.assertIn('rpc("claim_scholarship_delivery"', (root / "supabase/functions/_shared/scholarship-delivery.ts").read_text())
        self.assertIn("verifyProviderWebhookSignature", callback_edge)
        self.assertIn('rpc("process_scholarship_provider_event"', callback_edge)
        self.assertIn('rpc("get_scholarship_review_cv_path"', reviewer_cv_edge)
        self.assertIn("createSignedUrl", reviewer_cv_edge)
        self.assertIn('redirect: "error"', provider)
        self.assertIn("Idempotency-Key", provider)
        self.assertIn("createSignedUrl", (root / "supabase/functions/_shared/scholarship-delivery.ts").read_text())

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
            if path == self.TOKEN: continue
            for method, op in ops.items():
                if path == "/functions/v1/scholarship-provider-callback":
                    self.assertEqual(op.get("security"), [], "provider callback must use HMAC, not a Supabase JWT")
                    continue
                self.assertNotIn("security", op, f"{method.upper()} {path} overrides global security")

    def test_grant_types_and_bodies(self):
        op = API["paths"][self.TOKEN]["post"]
        param = next(p for p in op["parameters"] if p["name"] == "grant_type")
        self.assertEqual((param["in"], param["required"], set(param["schema"]["enum"])), ("query", True, {"password", "refresh_token"}))
        refs = [r["$ref"].rsplit("/", 1)[1] for r in op["requestBody"]["content"]["application/json"]["schema"]["oneOf"]]
        self.assertEqual(sorted(refs), ["PasswordGrantRequest", "RefreshTokenGrantRequest"])
        sch = API["components"]["schemas"]
        pw, rf = sch["PasswordGrantRequest"], sch["RefreshTokenGrantRequest"]
        self.assertEqual(set(pw["required"]), {"email", "password"})
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
