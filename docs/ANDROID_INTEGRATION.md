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

14. **Scholarship applications and external delivery**:
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
    - The current form stays unchanged: CV (optional), personal statement (maximum 10,000 characters) and flexible JSON answers (maximum 32 KiB). No per-Scholarship Form Builder is part of this contract.
    - Seeded listings have `is_sample=true` and are demonstration-only. They remain visibly sample and cannot be reviewed or accepted/rejected. Real Scholarships are created by Alumni Connect platform admins with `is_sample=false`; without an explicit provider mapping, applications enter the internal Alumni Connect review queue.
    - Platform admins create/update/publish/close Scholarships with `create_admin_scholarship`, `update_admin_scholarship`, `publish_admin_scholarship` and `close_admin_scholarship`. Creation starts in DRAFT; publishing moves to ACTIVE; closing moves DRAFT/ACTIVE to CLOSED. The listing is managed inside Alumni Connect; there is no external provider submission.
    - The central review queue uses `list_admin_scholarship_applications` (optional opportunity/status filters and paired cursor values); use `get_admin_scholarship_application` for applicant profile, CV id and submitted answers. Platform admins can download only CV objects attached to Scholarship applications; they cannot read unrelated graduates' CVs through this policy.
    - Review through `review_scholarship_application`: SUBMITTED → UNDER_REVIEW → ACCEPTED or REJECTED. Decisions cannot skip or reverse a stage. Each step records ADMIN_ACTION, actor, timestamp and optional note in status history, and creates a notification for the applicant. A student can withdraw only while SUBMITTED.
    - Applicants read their own status and history through the existing `scholarship_applications` and `scholarship_application_status_history` table paths.

    - **Never treat a locally saved application as an externally submitted application.** Without a provider mapping, the existing Alumni Connect workflow remains `SUBMITTED → UNDER_REVIEW → ACCEPTED|REJECTED` with `delivery_status=NOT_REQUIRED`. A platform admin explicitly opts a listing into external delivery by configuring a provider mapping. The provider-backed lifecycle is:
      - `PENDING_DELIVERY`: saved by this platform; provider has NOT confirmed receipt.
      - `SUBMITTED_EXTERNALLY`: only set after the provider returns a valid acknowledgement and external application reference.
      - `IN_REVIEW`: the organizer/provider or an authorized reviewer has begun reviewing it.
      - `ACCEPTED` / `REJECTED`: final decision received from the provider or authorized reviewer.
      - `DELIVERY_FAILED`: delivery exhausted its retry budget; a platform admin can queue a new attempt.
      - `INTERNAL_ONLY`: legacy compatibility state; new sample submissions remain `SUBMITTED` with `delivery_status=NOT_REQUIRED` and are never transmitted.
      - `WITHDRAWN`: withdrawn before external delivery. Once `SUBMITTED_EXTERNALLY`, withdrawal must be handled by the provider; the app will not claim it has been cancelled externally.
    - `delivery_status` is independent from application status: `NOT_REQUIRED`, `BLOCKED`, `PENDING`, `PROCESSING`, `DELIVERED`, `FAILED`, `CANCELLED`. No mapping means internal Alumni Connect review (`NOT_REQUIRED`); an explicitly configured but disabled mapping or missing server-side provider secret leaves provider delivery blocked/pending and never means the provider received it.
    - Read own submissions from `/rest/v1/scholarship_applications?select=*,opportunity:opportunities(title)` and status history from `/rest/v1/scholarship_application_status_history`. History identifies whether a transition came from the graduate, system, provider, reviewer or administrator.
    - Withdraw an application before delivery with `POST /rest/v1/rpc/withdraw_scholarship_application` and `{"p_application_id":"<application uuid>"}`. A request already processing or externally delivered cannot be locally withdrawn.
    - **Provider configuration is server-side only.** A platform admin maps a non-sample scholarship using `configure_scholarship_provider_mapping` with `p_opportunity_id`, `p_provider_key`, `p_external_opportunity_id`, and optional `p_is_enabled`. Credentials/endpoints are never stored in an opportunity row or shipped in the APK.
    - Configure the Edge Function secret `SCHOLARSHIP_PROVIDERS_JSON` as an object keyed by the same provider key. Example shape (replace all placeholders; never commit actual values):
      ```json
      {
        "PROVIDER_A": {
          "endpoint": "https://provider.example/api/v1/scholarship-applications",
          "bearer_token": "<provider-issued token>",
          "webhook_secret": "<random secret of at least 32 characters>"
        }
      }
      ```
      Endpoints must be HTTPS. Secrets belong in Supabase Edge Function secrets, not SQL, GitHub source, logs or Android configuration.
    - **Outgoing provider contract:** the backend POSTs JSON with `schema_version`, `event=scholarship.application.submitted`, `application_id`, `provider_opportunity_id`, `submitted_at`, `applicant`, `personal_statement`, `answers`, `cv_download_url`, and `idempotency_key`. It sends `Authorization: Bearer`, `Idempotency-Key`, `X-Alumni-Timestamp`, and `X-Alumni-Signature: sha256=<hex>`. The HMAC-SHA256 signature is over `timestamp + "." + raw_request_body`. The provider must deduplicate by `Idempotency-Key` and respond with a 2xx JSON body containing `{"accepted":true,"application_reference":"<provider id>"}`; optional `request_id` is retained for delivery audit.
    - If a CV is attached, the provider receives a private signed download URL that expires after 10 minutes. It must download the file during that window; the permanent Storage path and service-role credentials are never sent.
    - **Provider status callback:** configure the provider to POST to `/functions/v1/scholarship-provider-callback` with `provider_key`, unique `event_id`, `application_reference`, `status` (`IN_REVIEW`, `ACCEPTED`, or `REJECTED`), and optional `note`. Sign the exact raw JSON body with the shared webhook secret using the same timestamp/HMAC headers. Timestamps older than five minutes, invalid signatures, unknown references and invalid transitions are rejected. Repeated event IDs with the same payload are idempotent; reusing an event ID with a different payload is rejected.
    - **Internal Alumni Connect review:** without a provider mapping, platform admins use `list_admin_scholarship_applications` and `review_scholarship_application` for `SUBMITTED -> UNDER_REVIEW -> ACCEPTED|REJECTED`; sample listings remain non-reviewable. **External provider review:** after provider acknowledgement, a platform admin assigns a verified account with `set_scholarship_reviewer`; reviewers use `get_scholarship_review_queue` and the same review RPC for `SUBMITTED_EXTERNALLY -> IN_REVIEW -> ACCEPTED|REJECTED`. Reviewer access is scoped to its provider. Every transition writes history and a notification.
    - To view an attached CV during review, call `POST /functions/v1/get-scholarship-review-cv` with `{"application_id":"<id>"}`. The database verifies the reviewer's active provider assignment (or active platform-admin membership) before the Edge Function creates a private 10-minute signed URL. The reviewer URL never grants direct bucket access and cannot be used for another provider's application.
    - `deliver-scholarship` is a server worker: a trusted scheduler may invoke it with service-role authorization to process due retries; an active platform admin may invoke it for one application after the retry RPC. Never call it from a public client using a service-role key. The worker uses capped exponential backoff, a two-minute lease, a maximum of five automatic attempts, and the stable outbox UUID as its idempotency key.
    - Seeded/sample scholarships remain `SUBMITTED` with `delivery_status=NOT_REQUIRED`; provider mappings are forbidden for sample listings, so they are never sent externally.

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
    - This scope does not add followers, teams, direct messages, media uploads or moderation tools because those workflows are not defined in the current backend requirements.
