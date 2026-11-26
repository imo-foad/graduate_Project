# Android integration contract — Alumni Connect AI

Backend only: this repository contains the Supabase backend contract; the Android client is a separate Native Android/Kotlin + Jetpack Compose workstream. The machine-readable contract is `docs/openapi.yaml`.

## 1. Client configuration and security

The Android app receives only:
- `SUPABASE_URL`
- the Supabase anon/publishable key

Send `apikey: <anon key>` with every Auth, REST and Edge Function request. After authentication, send `Authorization: Bearer <access_token>` on authenticated requests.

Never ship a service-role key, National-ID HMAC secret, institutional provider token, SMS provider credential, demo password or AI key in the APK. Do not log or persist a raw National ID. A National ID is used only during institutional registration verification; it is never a login credential.

## 2. Registration: National ID + phone + password + OTP

Registration is a two-step flow. The client must not choose an account role.

**Step A — submit registration details**

```http
POST {SUPABASE_URL}/functions/v1/register
apikey: <anon key>
Content-Type: application/json

{
  "national_id": "<national ID>",
  "phone": "+201XXXXXXXXX",
  "password": "<password>",
  "full_name": "<full name>"
}
```

The phone must be E.164 format. The Edge Function asks the configured institutional identity provider to verify the National ID and the institution-provided affiliations. It then creates a phone Auth user, records only a keyed National-ID digest (not plaintext), and requests the mandatory SMS OTP.

Expected outcomes:
- `202 PENDING_OTP`: the account exists but is not active. Continue to SMS confirmation.
- `409 PHONE_ALREADY_REGISTERED` or `IDENTITY_ALREADY_LINKED`: resolve the existing account/identity; do not create aliases.
- `422`: invalid input or the provider rejected the identity.
- `503 IDENTITY_PROVIDER_UNAVAILABLE`: no approved provider/configuration is available. This is a real blocker, not a successful verification. Do not bypass it or fabricate an identity.
- `503 OTP_DELIVERY_FAILED`: the account remains pending and OTP delivery must be retried.

The mock identity provider is allowed only in explicitly configured disposable local tests. It must not silently replace an unavailable institutional provider in any shared or production environment.

**Step B — confirm the SMS code**

Use Supabase Auth's phone OTP verification flow (SMS type) with the phone number and the code sent to that number. Keep the resulting access token only after Auth confirms the phone.

Then call:

```http
POST {SUPABASE_URL}/functions/v1/finalize-registration
apikey: <anon key>
Authorization: Bearer <access_token>
Content-Type: application/json

{}
```

This activates the account only when both conditions are true:
1. Supabase Auth has a `phone_confirmed_at` timestamp.
2. At least one institution-verified human identity is present.

Until then, ordinary account operations are blocked. A pending owner may still read their own verification status/identities as documented.

## 3. Login and refresh

**Login uses phone + password only. Never send the National ID to the token endpoint.**

```http
POST {SUPABASE_URL}/auth/v1/token?grant_type=password
apikey: <anon key>
Content-Type: application/json

{
  "phone": "+201XXXXXXXXX",
  "password": "<password>"
}
```

**Refresh** uses only the latest refresh token:

```http
POST {SUPABASE_URL}/auth/v1/token?grant_type=refresh_token
apikey: <anon key>
Content-Type: application/json

{ "refresh_token": "<latest refresh_token>" }
```

Persist the new refresh token returned after each successful refresh. Never store a stale refresh token as the current token.

## 4. Human identities and account capabilities

One human account may have multiple institution-verified identities:
- `STUDENT`
- `GRADUATE`
- `FACULTY`

The institution provider determines the identities; the user cannot self-select or grant a privileged role. Use `POST /rest/v1/rpc/list_my_identities` to read the caller's own identities. The response is caller-scoped.

A `graduate_profiles` career profile is provisioned only for an institution-verified `GRADUATE` identity (legacy invitation/demo accounts remain compatible). A student/faculty-only identity must not be treated as a graduate just because it has an app account.

Companies are separate entities, not human account types. Company memberships use `OWNER`, `RECRUITER`, and `VIEWER`. Only `OWNER` and `RECRUITER` may manage opportunities or applications; `VIEWER` is read-only. Publishing requires a platform-verified company. Platform admin access is provisioned out-of-band and cannot be self-selected.

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

Call `POST /functions/v1/parse-cv` with `{ "cv_document_id": "<uuid>" }`. Digital-text PDF and DOCX parsing is supported. Scanned/image-only PDFs requiring OCR are not supported in the current scope. Extracted suggestions stay `PENDING` until the graduate explicitly reviews/accepts/rejects them; never treat extraction as verified profile data automatically. Review/adjust/reject pending suggestions using `POST /rest/v1/rpc/review_cv_suggestions` where available. The legacy skill-only `POST /rest/v1/rpc/confirm_cv_suggestions` accepts `p_confirm` and `p_reject` arrays; only confirmed suggestions become graduate profile skills.

Delete CV metadata using `POST /rest/v1/rpc/delete_cv_document`, not a direct table DELETE. This queues a durable server-side Storage-object cleanup. The operator-only `cleanup-cv-objects` worker removes bytes through the Storage API and records DONE/FAILED for retry/reconciliation. Never call the worker with a user token and never grant the app service-role access.

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
