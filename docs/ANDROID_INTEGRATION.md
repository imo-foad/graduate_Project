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

14. **Scholarship applications**:
    - List opportunities with GET `/rest/v1/opportunities?type=eq.SCHOLARSHIP&order=deadline.asc`.
    - Submit with POST `/rest/v1/rpc/apply_for_scholarship`:
      ```json
      {
        "p_opportunity_id": "<scholarship uuid>",
        "p_cv_document_id": "<own cv uuid or null>",
        "p_personal_statement": "Why I am applying...",
        "p_application_data": { "study_area": "Computer Science", "motivation": "Research" }
      }
      ```
    - Only `p_opportunity_id` is required. The CV must belong to the caller; the statement is limited to 10,000 characters and `p_application_data` must be a JSON object no larger than 32 KiB. Answers are stored without an imposed form schema because the current catalogue does not provide scholarship-specific questions.
    - The server checks opportunity type, open/deadline/end state, server-side eligibility and duplicate submissions. One submission per graduate/opportunity remains enforced after withdrawal.
    - Read own submissions from `/rest/v1/scholarship_applications?select=*,opportunity:opportunities(title)` and history from `/rest/v1/scholarship_application_status_history`.
    - Withdraw with POST `/rest/v1/rpc/withdraw_scholarship_application` and body `{"p_application_id":"<application uuid>"}`.
    - Seeded listings are sample data: requests are stored in this backend but are not transmitted to the named external provider. No external scholarship-provider integration is configured.

15. **Competition submissions**:
    - List competitions with GET `/rest/v1/opportunities?type=eq.COMPETITION&order=deadline.asc`.
    - Submit with POST `/rest/v1/rpc/apply_for_competition` using `p_opportunity_id`, optional caller-owned `p_cv_document_id`, optional `p_personal_statement` (maximum 10,000 characters), and a JSON object in `p_submission_data` (maximum 32 KiB). Example:
      ```json
      {
        "p_opportunity_id": "<competition uuid>",
        "p_cv_document_id": "<own cv uuid or null>",
        "p_personal_statement": "Overview of my entry...",
        "p_submission_data": { "project_title": "Campus Assist", "project_url": "https://example.test/project" }
      }
      ```
    - The server verifies COMPETITION type, open/deadline/end state, registration opening time, eligibility, CV ownership and duplicate prevention. One entry per graduate/competition remains enforced after withdrawal.
    - This is a competition-entry workflow, not `register_for_event`; the event-registration RPC continues to reject COMPETITION.
    - Read own entries from `/rest/v1/competition_applications?select=*,opportunity:opportunities(title)` and history from `/rest/v1/competition_application_status_history`; withdraw with POST `/rest/v1/rpc/withdraw_competition_application` and body `{"p_application_id":"<application uuid>"}`.
    - The entry payload is flexible because no authoritative team, judging, or competition-specific form schema exists in the catalogue. It stores the graduate's data in this backend; sample entries are not transmitted to the external organizer.

16. **Social Feed**:
    - Feed reads go through `POST /rest/v1/rpc/get_social_feed` with optional `p_limit` (1–50, default 20). For the next page send both `p_before_created_at` and `p_before_id` from the last item in the previous page; send both as null for the first page.
    - The response contains post content/timestamps, like/comment counts, `liked_by_me`, and only the author's display name plus avatar URL when `avatar_url` is not hidden in their profile preferences. Email, phone, college, major, CV and other profile fields are never part of this projection. Suspended authors are omitted; suspended accounts cannot use the feed.
    - Create a post with `POST /rest/v1/rpc/create_social_post` and `{ "p_content": "..." }`; edit with `update_social_post` and `{ "p_post_id": "<uuid>", "p_content": "..." }`; delete with `delete_social_post` and `{ "p_post_id": "<uuid>" }`. Post text must contain 1–5,000 characters after trimming.
    - Read comments with `POST /rest/v1/rpc/get_social_post_comments` using `p_post_id`, optional paired cursor values and `p_limit` (1–50). The response applies the same display-name/avatar privacy rules.
    - Add a comment with `add_social_comment` (`p_post_id`, `p_content`), edit your own with `update_social_comment` (`p_comment_id`, `p_content`) and delete your own with `delete_social_comment` (`p_comment_id`). Comment text must contain 1–2,000 characters after trimming.
    - Like/unlike using `like_social_post` or `unlike_social_post` with `p_post_id`. The feed returns only the total likes and the caller's `liked_by_me` flag; there is no endpoint exposing the identities of other likers.
    - All posts/comments/likes tables deny direct client table access; use these RPCs only. Posts can be edited/deleted only by their author; comments can be edited/deleted only by their author. Deleting a post cascades its comments and likes.
    - Users can report another graduate's post/comment with `POST /rest/v1/rpc/create_social_content_report` and `p_target_type` (`POST` or `COMMENT`), `p_target_id`, `p_category` (`SPAM`, `HARASSMENT`, `HATE_OR_VIOLENCE`, `THREATS`, `SCAM`, `PRIVACY`, `INAPPROPRIATE`, `OTHER`) and optional `p_details` (max 1,000 chars). A graduate can read only their own report status using `get_my_social_reports`; duplicate reports by the same user are rejected.
    - Platform administrators only can read `get_social_moderation_queue`, call `moderate_social_report` with `HIDE`, `REMOVE` or `DISMISS`, restore reviewed content with `restore_social_content`, and read `get_social_moderation_history`. Every moderation action is recorded in a private append-only audit log. Moderated content is omitted from feed/comments; authors cannot edit content while it is hidden/removed.
    - All Social Feed write limits are per-user token buckets enforced in PostgreSQL (not only Android): post creation 5 initial tokens/refill 5 per minute; post edits 10/min; comments 12/min; comment edits 20/min; likes 30/min; reports 5/hour. CV parsing is limited to 5/hour; recommendations 30/min; forced recommendation recomputations 10/hour. Exceeded limits return HTTP 429. Social RPC errors expose `retry_after_seconds` in the error details; CV parsing and recommendation Edge Functions also return the `Retry-After` response header. An unavailable rate-limit store fails closed with HTTP 503 for Edge Functions.
    - This version still does not add followers, teams, direct messages or media uploads; those remain outside this backend scope.
