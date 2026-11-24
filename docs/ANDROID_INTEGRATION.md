# Android integration notes (backend contract v0.2)

Backend only: no Android code lives here. Full contract: `docs/openapi.yaml` (checked against the SQL by `npm run test:contract`).

1. **Config** the app needs: `SUPABASE_URL` and the **anon/publishable key** only. Never ship the service-role key,
   `DEMO_PASSWORD`, or any AI key in the APK.
2. **Headers.** EVERY request carries `apikey: <anon key>`. Every request except login/refresh also carries
   `Authorization: Bearer <access_token>`.
3. **Login** (password grant; no sign-up, no role selection):
   ```
   POST {SUPABASE_URL}/auth/v1/token?grant_type=password
   apikey: <anon key>
   {"email": "graduate.demo@alumni.test", "password": "<from team>"}
   ```
   **Refresh** (refresh_token grant: body has ONLY the refresh token, no email/password):
   ```
   POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token
   apikey: <anon key>
   {"refresh_token": "<refresh_token from the last response>"}
   ```
   Both return `access_token`, `refresh_token`, `expires_in`. Store the NEW refresh token after every refresh.
   400 = bad credentials / used refresh token, 401 = missing or wrong `apikey`.
4. **Never send a graduate id** to an RPC: identity comes from the JWT. (Direct inserts into `graduate_skills`,
   `saved_opportunities` carry `graduate_id` = your own uid; any other value is rejected by RLS.)
5. **Catalogue is read-only**: GET `/rest/v1/opportunities` with PostgREST filters/pagination. There are no write endpoints.
6. **Errors**: RPC failures return HTTP 401/404/409/422 with `{"message": "<CODE>", "details": ...}`.
   Map `message` to UI strings: `ALREADY_APPLIED`, `ALREADY_REGISTERED`, `EVENT_FULL`, `OPPORTUNITY_CLOSED`,
   `REGISTRATION_CLOSED`, `NOT_ELIGIBLE` (details = failed requirements), `CANNOT_WITHDRAW`, ...
7. **Application status**: new applications are `SUBMITTED` (or `WITHDRAWN`). Statuses starting with `SAMPLE_`
   (`status_source = SEED_SAMPLE`) are demo history: label them as sample data in the UI (BR-011/BR-023).
8. **Recommendations**: `POST /functions/v1/recommend` (cached unless profile inputs changed). Show `score` as
   "Match Score" with the band, reasons and gaps, plus the disclaimer. It is not a hiring probability.
   **New in v0.2:** it can answer `409 {"error":"STALE_SNAPSHOT","retryable":true}` when the profile kept changing during
   the calculation; the previous cache is intact, so show it (or a spinner) and call again later. `ai_mode` is
   `deterministic`; if the call fails, keep manual search/filter working (BR-021).
9. **CV upload** (CV parsing endpoint is not implemented yet): upload to bucket `cv-documents` at path
   `<uid>/<file>.pdf|docx` (max 5 MB), then insert a `cv_documents` row (`graduate_id`, `storage_path`, `file_type`, `size_bytes`).
10. **Notifications**: in-app only (`notifications` table); no FCM in this scope.
