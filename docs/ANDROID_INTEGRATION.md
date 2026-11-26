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
5. **Catalogue is read-only**: GET `/rest/v1/opportunities` with PostgREST filters/pagination. Do not write catalogue or activity tables directly; use the documented business-rule RPCs for submissions and registrations.
6. **Errors**: RPC failures return HTTP 401/404/409/422 with `{"message": "<CODE>", "details": ...}`.
   Map `message` to UI strings: `ALREADY_APPLIED`, `ALREADY_REGISTERED`, `EVENT_FULL`, `OPPORTUNITY_CLOSED`,
   `REGISTRATION_CLOSED`, `NOT_ELIGIBLE` (details = failed requirements), `CANNOT_WITHDRAW`, ...
7. **Application status**: new applications are `SUBMITTED` (or `WITHDRAWN`). Statuses starting with `SAMPLE_`
   (`status_source = SEED_SAMPLE`) are demo history: label them as sample data in the UI (BR-011/BR-023).
8. **Recommendations**: `POST /functions/v1/recommend` (cached unless profile inputs changed). Show `score` as
   "Match Score" with the band, reasons and gaps, plus the disclaimer. It is not a hiring probability.
   **Availability (v0.4):** every item carries `availability_status`. `OPEN` = register now; `UPCOMING` =
   `opportunity.registration_opens_at` is in the future (score is 0, so it ranks low but stays discoverable);
   `WAITLIST_ONLY` = capacity is reached but `waitlist_enabled`, so label the action "Join waitlist"; `null` =
   the opportunity has no registration window/capacity (jobs, internships). Closed opportunities and full
   events without a waitlist are never returned, cached or fresh, so the app cannot offer a registration that
   the backend would reject with `EVENT_FULL`/`REGISTRATION_CLOSED`.
   **New in v0.2:** it can answer `409 {"error":"STALE_SNAPSHOT","retryable":true}` when the profile kept changing during
   the calculation; the previous cache is intact, so show it (or a spinner) and call again later. `ai_mode` is
   `deterministic`; if the call fails, keep manual search/filter working (BR-021).
   The same response includes `career_profile`: `primary_path` is the highest-ranked inferred path and
   `paths` contains every path supported by at least two core skills. Each path includes a 0–100 weighted
   skill-coverage score, matched core/supporting skills, missing core skills, up to three next skills, and
   Arabic explanation. Core skills count three times as much as supporting skills; proficiency levels are
   normalized against the catalogue's 1–5 scale. Backend, Data Science and Cybersecurity also require at least one path-specific signal, so general-purpose languages, analytics fundamentals or networking alone do not falsely imply a specialization. Frontend, Backend, Data Analytics, Data Science and
   Cybersecurity are explicitly mapped; other existing paths (Mobile, DevOps/Cloud, QA and UI/UX) remain
   available. One graduate may match several paths. The score is an explainable skills-coverage indicator,
   not a hiring probability. Only rows in `graduate_skills` are considered; pending CV suggestions are excluded.
9. **CV upload and parsing**: upload to private bucket `cv-documents` at `<uid>/<file>.pdf|docx` (max 5 MB),
   then insert `cv_documents` metadata (`graduate_id`, `storage_path`, `file_type`, `size_bytes`). Call
   `POST /functions/v1/parse-cv` with `{ "cv_document_id": "<id>" }`; the verified JWT determines ownership.
   Digital-text PDF and DOCX files are parsed for dictionary-matched skills plus section-based work experience,
   certifications and courses. Every extracted item is a `PENDING` row in `cv_suggestions`; education and
   projects are intentionally ignored. Review/adjust/reject items through
   `POST /rest/v1/rpc/review_cv_suggestions` with `p_decisions: [{id,status,payload?}]`. Only confirmed items
   reach `graduate_skills`, `career_history`, `certifications` or `courses`. The older
   `confirm_cv_suggestions` RPC remains available for skill-only clients. Scanned/image-only PDFs requiring OCR
   are not supported by the free local parser.
10. **Notifications**: in-app only (`notifications` table); no FCM in this scope.


11. **Career market gaps**: call `POST /rest/v1/rpc/get_career_market_insights`. Demand counts are based only on
    active JOB/INTERNSHIP posts in this platform, not an external market survey. The response includes your confirmed
    skills, experience years, top-demand skills and missing skills with matching learning opportunities.
12. **Recommendation feedback**: use `POST /rest/v1/rpc/record_recommendation_interaction` to log
    `IMPRESSION`, `VIEW`, `DISMISS` or `NOT_INTERESTED` for a recommendation owned by the caller. SAVE,
    APPLY and REGISTER are captured automatically from their existing operations. A later view/save/apply/register
    can reactivate an opportunity previously dismissed.
13. **Job experience requirement**: the company owner/recruiter (or platform admin) calls
    `POST /rest/v1/rpc/set_job_experience_requirement` while the job is DRAFT with
    `p_opportunity_id`, `p_minimum_experience_years` (number or null) and `p_is_required`. Mandatory minimums
    exclude candidates below the threshold; preferred minimums reduce the experience match score.

14. **Cancelled product lines — Scholarship and Competition**: these features were removed from the active
    product scope by product decision. Do not build screens for them and do not call their old endpoints.
    - `SCHOLARSHIP` and `COMPETITION` are inactive opportunity types. They are excluded from
      `/rest/v1/opportunities` discovery, from the deterministic recommendation engine and from all cached
      recommendations. Sample rows were removed from the seed catalogue.
    - The former RPCs (`apply_for_scholarship`, `withdraw_scholarship_application`, `apply_for_competition`,
      `withdraw_competition_application`, the internal scholarship admin and delivery routines) return HTTP 403
      for client roles. The former Edge Functions (`submit-scholarship`, `deliver-scholarship`,
      `get-scholarship-review-cv`, `scholarship-provider-callback`) are no longer deployed.
    - The `scholarship_applications`, `scholarship_application_status_history`, `competition_applications` and
      `competition_application_status_history` table paths are not readable by clients. Historical rows are
      retained server-side only for data integrity; there is no client API for them.
    - Any client behaviour that previously depended on these features should be removed rather than hidden.

15. **Opportunity-type scope**: the only active types are `JOB`, `INTERNSHIP`, `TRAINING`, `EVENT`,
    `CONFERENCE` and `VOLUNTEER`. The backend rejects creation of any other type with
    `CANCELLED_OPPORTUNITY_TYPE`, and clients should treat the `type` field as an open-ended string that may
    gain new values in the future instead of hard-coding the cancelled ones.

16. **Social Feed**:
    - Feed reads go through `POST /rest/v1/rpc/get_social_feed` with optional `p_limit` (1–50, default 20). For the next page send both `p_before_created_at` and `p_before_id` from the last item in the previous page; send both as null for the first page.
    - The response contains post content/timestamps, like/comment counts, `liked_by_me`, and only the author's display name plus avatar URL when `avatar_url` is not hidden in their profile preferences. Email, phone, college, major, CV and other profile fields are never part of this projection. Suspended authors are omitted; suspended accounts cannot use the feed.
    - Create a post with `POST /rest/v1/rpc/create_social_post` and `{ "p_content": "..." }`; edit with `update_social_post` and `{ "p_post_id": "<uuid>", "p_content": "..." }`; delete with `delete_social_post` and `{ "p_post_id": "<uuid>" }`. Post text must contain 1–5,000 characters after trimming.
    - Read comments with `POST /rest/v1/rpc/get_social_post_comments` using `p_post_id`, optional paired cursor values and `p_limit` (1–50). The response applies the same display-name/avatar privacy rules.
    - Add a comment with `add_social_comment` (`p_post_id`, `p_content`), edit your own with `update_social_comment` (`p_comment_id`, `p_content`) and delete your own with `delete_social_comment` (`p_comment_id`). Comment text must contain 1–2,000 characters after trimming.
    - Like/unlike using `like_social_post` or `unlike_social_post` with `p_post_id`. The feed returns only the total likes and the caller's `liked_by_me` flag; there is no endpoint exposing the identities of other likers.
    - All posts/comments/likes tables deny direct client table access; use these RPCs only. Posts can be edited/deleted only by their author; comments can be edited/deleted only by their author. Deleting a post cascades its comments and likes.
    - This scope does not add followers, teams, direct messages or media uploads. Moderation and reporting are available through the dedicated admin RPCs documented in `docs/openapi.yaml`.
