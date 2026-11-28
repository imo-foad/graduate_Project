# Android integration contract — Alumni Connect AI

Backend only: this repository contains the Supabase backend contract; the Android client is a separate Native Android/Kotlin + Jetpack Compose workstream. The machine-readable contract is `docs/openapi.yaml`.

## 1. Client configuration and security

The Android app receives only:
- `SUPABASE_URL`
- the Supabase anon/publishable key

Send `apikey: <anon key>` with every Auth, REST and Edge Function request. After authentication, send `Authorization: Bearer <access_token>` on authenticated requests.

Never ship a service-role key, demo password or AI key in the APK. Do not log or persist the raw synthetic identifier. The synthetic identifier is used only during demo registration verification; it is never a login credential. There is no National-ID HMAC secret, institutional provider token or SMS provider credential in this demo flow.

## 2. Registration: email + password + synthetic identity

Registration is a two-step flow. The client must not choose an account role. The university demo
does **not** call a real institutional provider and does **not** send an SMS OTP. It verifies a
clearly fake `SYNTH-...` identifier against the backend's local synthetic registry. This is demo
verification only, never a real National-ID or institutional claim.

**Step A — submit registration details**

```http
POST {SUPABASE_URL}/functions/v1/register
apikey: <anon key>
Content-Type: application/json

{
  "email": "student@example.test",
  "phone": "+201XXXXXXXXX",
  "password": "<password>",
  "full_name": "<full name>",
  "synthetic_id": "SYNTH-STUDENT-0001"
}
```

`email` is the canonical Auth identifier and the confirmation target. `phone` is optional contact
data; it is never used as an Auth identifier and never triggers an SMS. `synthetic_id` must be one of
the fake identifiers seeded in the private local registry. A real-looking 14-digit National ID is
rejected with `422 INVALID_SYNTHETIC_ID`; an unknown `SYNTH-...` value is rejected with
`422 SYNTHETIC_IDENTITY_NOT_FOUND`.

Expected outcomes:
- `202 PENDING_EMAIL_VERIFICATION`: the account and synthetic identities exist, but the account is
  not active. The body reports `email_confirmation: "REQUESTED"` and
  `email_delivery: "UNCONFIRMED"`. Auth accepting the request is **not** proof that the email was
  delivered. Do not show a "delivered" message; tell the user to check their inbox.
- `409 EMAIL_ALREADY_REGISTERED`, `PHONE_ALREADY_REGISTERED` or `IDENTITY_ALREADY_LINKED`: resolve
  the existing account/identity; do not create aliases.
- `422 INVALID_SYNTHETIC_ID` or `SYNTHETIC_IDENTITY_NOT_FOUND`: the demo identifier is not in the
  local registry. Do not bypass this or fabricate an identity.
- `429 EMAIL_RESEND_COOLDOWN`: an explicit resend was requested too soon. Respect
  `retry_after_seconds` and show the user when another resend can be requested.
- `429 EMAIL_RESEND_MAX_ATTEMPTS`: the five-attempt confirmation-email budget is exhausted.
- `503 EMAIL_CONFIRMATION_REQUEST_FAILED`: the pending account and identity association remain.
  Do not claim delivery. The user may explicitly request a resend after the cooldown.
- **Idempotent retry:** resubmitting the same `email` + `synthetic_id` pair without
  `resend_confirmation` resumes only that exact pending account and does not send a duplicate email.
  It returns `email_confirmation: ALREADY_REQUESTED` when a send was already claimed.
- **Explicit resend:** include `"resend_confirmation": true` only after the user taps a resend action.
  The backend enforces a 60-second cooldown and a maximum of five total attempts (including the first).
  A different identity cannot recover an orphaned pending account because recovery requires the exact
  digest stored in Auth Admin-owned `app_metadata`. This retry does not change the existing password;
  use password recovery if it must be changed.

**Step B — confirm the email**

Supabase sends a confirmation link to the address. The Android client opens that link (deep link or
browser) and Supabase returns a session in the redirect fragment. Keep the resulting access token
only after the email is confirmed. Then call:

```http
POST {SUPABASE_URL}/functions/v1/finalize-registration
apikey: <anon key>
Authorization: Bearer <access_token>
Content-Type: application/json

{}
```

This activates the account only when both conditions are true:
1. Supabase Auth has an `email_confirmed_at` timestamp.
2. At least one verified synthetic identity is associated with the account.

Until then, ordinary account operations are blocked. A pending owner may still read their own
verification status/identities as documented. Phone confirmation is not required and is not checked.

## 3. Login and refresh

**New email-first accounts use email + password.** Legacy synthetic demo accounts keep phone +
password compatibility.

```http
POST {SUPABASE_URL}/auth/v1/token?grant_type=password
apikey: <anon key>
Content-Type: application/json

{
  "email": "student@example.test",
  "password": "<password>"
}
```

For a legacy demo account, send `phone` instead of `email`. Never send the synthetic identifier or
any National ID to the token endpoint.

**Refresh** uses only the latest refresh token:

```http
POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token
apikey: <anon key>
Content-Type: application/json

{ "refresh_token": "<latest refresh_token>" }
```

Persist the new refresh token returned after each successful refresh. Never store a stale refresh
token as the current token.

## 4. Human identities and account capabilities

One human account may have multiple verified synthetic identities:
- `STUDENT`
- `GRADUATE`
- `FACULTY`

The local synthetic registry determines the identities; the user cannot self-select or grant a privileged role. Every such identity is marked `SYNTHETIC_SEED` and is demo data, not institutional verification. Use `POST /rest/v1/rpc/list_my_identities` to read the caller's own identities. The response is caller-scoped.

A `graduate_profiles` career profile is provisioned only for a verified `GRADUATE` identity (legacy invitation/demo accounts remain compatible). A student/faculty-only identity must not be treated as a graduate just because it has an app account.

Companies are separate entities, not human account types. Company memberships use `OWNER`, `RECRUITER`, and `VIEWER`. Only `OWNER` and `RECRUITER` may manage opportunities or applications; `VIEWER` is read-only. Publishing, new applications and recommendation discovery require a platform-verified company. A transition to `SUSPENDED` or `REJECTED` invalidates cached recommendations and removes that company's listings from fresh candidate results. While unverified, members cannot edit an `ACTIVE` listing; they may close it as a safe deactivation action. DRAFT editing is allowed, but publishing still requires verification. Platform admin access is provisioned out-of-band and cannot be self-selected.

## 5. Opportunity catalogue

The only active product types are:
- `JOB`
- `INTERNSHIP`
- `TRAINING`

`EVENT`, `CONFERENCE`, `VOLUNTEER`, `SCHOLARSHIP` and `COMPETITION` are not active product types. Existing historical records are retained for audit/integrity, but must not be presented as actionable opportunities or reactivated.

Read the catalogue using `GET /rest/v1/opportunities` with PostgREST filters, pagination and an explicit selection, for example:

```
?type=eq.JOB&order=deadline.asc&limit=20&offset=0&select=*,job_details(*),opportunity_skills(*),requires_cv
```

The catalogue is read-only to clients. Do not insert, update or delete opportunity rows directly.

## 6. JOB and INTERNSHIP applications

JOB and INTERNSHIP share the same application lifecycle. Both use `POST /rest/v1/rpc/apply_for_job` (the historical RPC name is kept for compatibility):

```json
{
  "p_opportunity_id": "<uuid>",
  "p_cv_document_id": null,
  "p_note": "Optional note"
}
```

CV is optional by default. A verified company OWNER/RECRUITER may set `requires_cv=true` for a specific JOB/INTERNSHIP while that opportunity is still DRAFT, using `POST /rest/v1/rpc/set_opportunity_cv_requirement`. If required, the applicant must supply an active CV document owned by the applicant. An uploaded but inactive or another user's CV is not sufficient.

Candidate application states and allowed movement:

- `SUBMITTED` → `UNDER_REVIEW`, `REJECTED`, or candidate `WITHDRAWN`.
- `UNDER_REVIEW` → `SHORTLISTED`, `REJECTED`, or candidate `WITHDRAWN`.
- `SHORTLISTED` → `INTERVIEW`, `REJECTED`, or candidate `WITHDRAWN`.
- `INTERVIEW` → `ACCEPTED`, `REJECTED`, or candidate `WITHDRAWN`.
- `ACCEPTED`, `REJECTED` and `WITHDRAWN` are terminal.

Company OWNER/RECRUITER or platform admin processes employer decisions through `POST /rest/v1/rpc/update_application_status`. Candidates withdraw through `POST /rest/v1/rpc/withdraw_application` from any non-terminal phase. No status skipping, reopening or reapplication after `WITHDRAWN` is allowed. The server writes status history and sends in-app notifications; the app should render the persisted status rather than infer transitions.

The unique application key is per graduate and opportunity; a withdrawn application remains in history and cannot be resubmitted.

## 7. TRAINING direct registration and FIFO waitlist

TRAINING registration is direct; no organizer approval is part of this flow. Use:
- `POST /rest/v1/rpc/register_for_event` to register or join the waitlist.
- `POST /rest/v1/rpc/cancel_event_registration` to cancel your registration.

The RPC names are historical; the active contract is TRAINING-only. A full program without waitlist enabled returns `EVENT_FULL`. If waitlist is enabled, participants enter FIFO order by `registered_at`, then stable registration ID.

When a confirmed `REGISTERED` participant cancels, the backend decrements the confirmed counter and promotes the oldest eligible `WAITLISTED` participant in the same database transaction. The promoted participant receives an in-app notification. Ineligible queue entries are skipped but remain WAITLISTED for audit/review. If the training is closed/cancelled, registration window has not opened, or waitlisting is disabled, no promotion occurs. Cancelling a `WAITLISTED` participant does not free a seat and does not trigger promotion.

Read current registrations from `/rest/v1/event_registrations`, and their append-only lifecycle from `/rest/v1/event_registration_status_history`. The server records candidate actions and automatic promotion as separate history sources.

## 8. CV upload, parsing and deletion

Upload CV files only to the private `cv-documents` bucket under `<uid>/<filename>.pdf|docx` (maximum 5 MB), then create the caller-owned `cv_documents` metadata. Do not make the bucket public.

Call `POST /functions/v1/parse-cv` with `{ "cv_document_id": "<uuid>" }`. Digital-text PDF and DOCX parsing is supported. Scanned/image-only PDFs requiring OCR are not supported in the current scope. PDF text is reconstructed from positioned text runs, so a two-column CV is read column by column and an employer/title gap is kept as a separate field instead of being merged; DOCX tables keep each cell boundary. Arabic diacritics, tatweel and punctuation are normalized for skill matching while the stored suggestion text is preserved. Extracted suggestions stay `PENDING` until the graduate explicitly reviews/accepts/rejects them; never treat extraction as verified profile data automatically. Extraction quality is measured only on a curated synthetic corpus: do not present parser output as guaranteed-correct for real CVs, and keep OCR out of scope until the product owner approves a privacy-safe approach. Review/adjust/reject pending suggestions using `POST /rest/v1/rpc/review_cv_suggestions` where available. The legacy skill-only `POST /rest/v1/rpc/confirm_cv_suggestions` accepts `p_confirm` and `p_reject` arrays; only confirmed suggestions become graduate profile skills.

Delete CV metadata using `POST /rest/v1/rpc/delete_cv_document`, not a direct table DELETE. This queues a durable server-side Storage-object cleanup. The operator-only `cleanup-cv-objects` worker removes bytes through the Storage API and records DONE/FAILED for retry/reconciliation. A FAILED row follows bounded exponential backoff (60 seconds doubling, capped at 30 minutes); abandoned 15-minute worker leases are recovered and reclaimed transactionally. After ten unsuccessful claims, a row remains visible as exhausted until an operator explicitly requeues it. Every `storage_path` that enters the private cleanup queue becomes a permanent tombstone: PENDING, PROCESSING, FAILED and DONE paths cannot be registered again, and CV metadata writes/deletions are serialized with queue insertion by transaction-scoped advisory locks. Every replacement CV must use a fresh unique Storage path. The reconciliation report separates retry-ready, retry-scheduled and exhausted rows. Never call the worker with a user token and never grant the app service-role access.

## 9. Recommendations and career insights

Call `POST /functions/v1/recommend` to refresh recommendations. Show the score as a skills/profile match indicator, not a hiring probability. Use its availability field when present:
- `OPEN`: registration can be started now.
- `UPCOMING`: registration window has not opened.
- `WAITLIST_ONLY`: capacity is reached but a waitlist is enabled.
- `null`: availability is not modelled for this opportunity (for example, a JOB or INTERNSHIP).

Closed opportunities and full TRAINING without waitlist are not actionable recommendations. If recommendation generation returns retryable `STALE_SNAPSHOT`, keep the previously displayed cache and retry rather than discarding it.

Use `POST /rest/v1/rpc/get_career_market_insights` for the platform's career-demand and skill-gap insights. Demand is computed from this platform's active JOB/INTERNSHIP catalogue, not an external labour-market survey.

## 10. In-app notifications

Read `/rest/v1/notifications?order=created_at.desc`. Mark only the caller's own notification as read using the documented `is_read` update. In-app notifications are the product scope; FCM/push delivery is not required currently.

## 11. Social Feed

Social Feed remains a core product capability and must not regress. Use the documented RPCs in `docs/openapi.yaml` for keyset-paginated feed reads, post/comment creation and edits, likes, reports and moderation. Do not write social tables directly. Feed projections expose only display name and avatar when not hidden by profile privacy settings; do not expect email, phone, CV or private education fields in the feed.

## 12. General client rules

- Never send another user's profile ID as an identity input; normal authenticated RPCs derive the caller from the JWT.
- Never write catalogue, application state, training counters, training status history, notification content or social moderation tables directly.
- Treat stable RPC error `message` values as user-facing business outcomes; use `details` only where the contract documents safe requirement information.
- Distinguish seeded sample history (`status_source = SEED_SAMPLE`) from real applications.
- Do not implement tuition/fees, instalments, financial assistance, lectures, exams or course-content features in this app scope.

## Student and faculty academic records

Migration 0034 adds typed `student_academic_records` and `faculty_academic_records`. Authenticated users may read only their own academic row under RLS; writes are service-role only. Student rows expose department, major, academic track, academic level, GPA and explicit `gpa_scale=4.0`. This is a synthetic local fixture convention, not an institutional grading policy. Synthetic identities have `verification_source=SYNTHETIC_SEED` and must never be presented as institution-verified. Administrators are represented only by `private.platform_admins`, not by a public human identity type.
