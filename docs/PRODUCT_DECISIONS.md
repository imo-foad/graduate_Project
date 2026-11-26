# Alumni Connect — Product Decisions

**Status:** FINAL — product-owner approved  
**Decision date:** 2026-11-26  
**Applies to:** Backend, database, Supabase Auth, Edge Functions, API contracts, Android integration and tests  
**Authority:** This document is the authoritative product-decision record. It supersedes conflicting assumptions in older Issues, migrations, comments, prompts and documentation. Historical migrations are never rewritten.

---

## 1. Product definition

Alumni Connect is a career platform for opportunities and professional development, serving students, graduates, faculty members, companies, institutions and approved organizations.

The platform's active opportunity catalogue is deliberately limited to three core types:

| Opportunity type | Approved meaning | Active |
|---|---|---:|
| `JOB` | Employment and job vacancies | Yes |
| `INTERNSHIP` | Practical work experience and internships | Yes |
| `TRAINING` | Training programmes and skills development | Yes |
| `EVENT` | Standalone events | No |
| `CONFERENCE` | Standalone conferences | No |
| `VOLUNTEER` | Standalone volunteer opportunities | No |
| `SCHOLARSHIP` | Scholarship programmes | No |
| `COMPETITION` | Competitions | No |

**Final decision:** the active core is `JOB`, `INTERNSHIP`, and `TRAINING` only.

Events, conferences and volunteering are not independent opportunity types in this product scope. A professional event may be described or announced through an appropriate existing product surface where supported, but must not be represented as an active opportunity type or consume the Job/Internship/Training application or registration workflows.

Scholarships and Competitions remain permanently cancelled.

### Historical data and forward-only scope enforcement

- Never delete historical opportunity, application, registration or audit rows merely to enforce product scope.
- Keep old migrations immutable.
- Use a new forward-only migration to make SQL's active-type predicate accept exactly `JOB`, `INTERNSHIP`, and `TRAINING`.
- Reject creation or reactivation of excluded types through database/server enforcement, not just UI validation.
- Exclude excluded types from discovery, recommendation candidates, fresh results, cached results, registration and application entry points.
- Preserve historical rows for audit and referential integrity. Deactivate existing excluded opportunities safely; do not expose them as currently actionable opportunities.
- Existing historical migrations may contain old enums and functions. Their presence is not permission to re-enable those features.
- TypeScript, SQL, API schemas, seed validation, fixtures and Android contracts must agree on the same active allow-list.

---

## 2. Human identity and authentication

### 2.1 Registration

A new human account requires:

1. National ID.
2. Phone number.
3. Password.
4. Successful verification of the National ID against the institution's authoritative data source.
5. Successful phone OTP verification.

Both identity verification and phone ownership verification are mandatory before the account is activated for normal platform use.

The National ID is an identity-verification attribute, not a login credential.

### 2.2 Login

Login uses **phone number + password only**.

- Do not use National ID to log in.
- Do not substitute email/password for the approved phone/password flow.
- Do not create fake email aliases from a phone number or National ID.
- Use Supabase phone/password Auth, subject to verification against the current supported Supabase Auth flow.
- OTP is mandatory during registration to prove control of the phone number. Login itself remains phone/password; do not add an OTP challenge to every login unless a future security decision explicitly changes this.

### 2.3 One human account, multiple verified identities

The human identity types are:

- `STUDENT`
- `GRADUATE`
- `FACULTY`

One human has one authenticated account and may hold more than one legitimate institutional identity/affiliation at the same time.

Examples include a graduate who is also a faculty member, or a student who later becomes a graduate.

Rules:

- The user must never grant themselves a role by sending a role string or editing profile metadata.
- The institution's authoritative response determines verified identities and relevant attributes.
- Model identities/affiliations as multiple verified relationships attached to one human account, rather than creating duplicate Auth accounts for each role.
- Role transitions must preserve account continuity, relevant history and ownership.
- Server-side authorization must check verified identity/affiliation and account state. Client-supplied role metadata is never authoritative.
- Do not assume that every human can hold every role; accept only combinations confirmed by the institutional source.

### 2.4 Sensitive National ID handling

- Do not return a National ID from public APIs.
- Do not place it in JWT claims, analytics, ordinary logs, exception text, notifications or client metadata.
- Minimize retention.
- If uniqueness or matching requires persistence, use a reviewed protected design such as encrypted storage plus a keyed deterministic lookup digest, with secrets outside source control.
- Never use a plain unkeyed hash as the security design for a low-entropy identifier.
- Document access controls, retention, deletion and key rotation.
- Use synthetic identifiers only in tests.

---

## 3. Phone OTP and external identity verification

### Phone OTP

OTP verification is mandatory during registration.

Use Supabase Auth's supported phone verification mechanism and an approved SMS delivery provider/configuration. Validate the current Supabase version and supported flow before implementation.

A mock SMS/OTP adapter is allowed only in disposable local tests. It is not evidence that real SMS delivery is configured.

### Institutional National ID provider

The institution's authoritative data source must determine whether the National ID belongs to a valid institutional person and which human identities/attributes are verified.

Do not invent:
- an institution endpoint,
- a database schema,
- credentials,
- student/faculty records,
- or a successful verification response.

Implement a provider abstraction, response normalization, safe retries, timeouts, idempotency, audit events and a deterministic local mock.

The actual identity integration remains externally dependent until the institution supplies an approved API/database contract and authorized test access.

The rest of onboarding must continue to be implemented and tested with synthetic identities and the local mock.

---

## 4. Companies, institutions and organizations

Human accounts authenticate individually. Companies, institutions and other approved organizations are separate platform identities, not shared-login accounts.

### Company publishing

**A company must be VERIFIED before it can publish a JOB or INTERNSHIP.**

- Unverified, rejected or suspended companies cannot publish.
- Company creation does not itself imply verification.
- Verification is performed by an authorized platform administrator using a documented manual review workflow unless an approved external verification source is later provided.
- Preserve verification status history, decision-maker, timestamps and review notes.
- A rejected company may submit corrected evidence for a new review.
- Suspending a company must prevent new publication and, according to a documented operational rule, prevent unauthorized further management of active listings.

### Membership roles

Use individual human accounts linked to organization identities through memberships.

Minimum company roles:

| Role | Permissions |
|---|---|
| `OWNER` | Manage company identity, memberships and all company opportunities |
| `RECRUITER` | Create/manage opportunities and process applications |
| `VIEWER` | Read-only company access |

- Do not let members grant themselves higher roles.
- Only an authorized owner/platform admin may change membership roles or transfer ownership.
- Record the organization identity and the actual authenticated human actor on every organization action.
- Cross-company data access is prohibited by RLS and server-side authorization.

Institutions and other organizations must follow the same separate-identity and verified-membership principles where they are enabled.

### Platform administrators

- Never create an admin through a public signup parameter or client-editable role.
- Use secure out-of-band bootstrap with the minimum privileges and an audit trail.
- Never ship service-role credentials to Android.

---

## 5. JOB and INTERNSHIP application workflow

### Same workflow

**INTERNSHIP uses the same application workflow as JOB.**

Both use the same core application lifecycle, ownership rules, candidate privacy, company permissions, CV requirements and notification semantics.

The opportunity's `type` is the authoritative distinction between `JOB` and `INTERNSHIP`. Do not confuse `opportunities.type` with the employment/engagement attributes in `job_details`.

The server may retain a compatibility RPC name such as `apply_for_job`, but its business contract must support both approved types or be replaced with a clearly named shared application operation. Do not leave Internship discoverable but impossible to apply for.

### Application statuses and transitions

Use the following strict lifecycle:

```text
SUBMITTED
   |
   v
UNDER_REVIEW
   |
   v
SHORTLISTED
   |
   v
INTERVIEW
   |             |
   v             v
ACCEPTED       REJECTED
```

A company may reject an application from any non-terminal review stage. A candidate may withdraw while the application is non-terminal.

Allowed transitions:

| Current status | Allowed next status |
|---|---|
| `SUBMITTED` | `UNDER_REVIEW`, `REJECTED`, `WITHDRAWN` |
| `UNDER_REVIEW` | `SHORTLISTED`, `REJECTED`, `WITHDRAWN` |
| `SHORTLISTED` | `INTERVIEW`, `REJECTED`, `WITHDRAWN` |
| `INTERVIEW` | `ACCEPTED`, `REJECTED`, `WITHDRAWN` |
| `ACCEPTED` | No further transition |
| `REJECTED` | No further transition |
| `WITHDRAWN` | No further transition |

Rules:

- Do not permit skipping a required forward stage, reopening a terminal status, or arbitrary status assignment.
- Only the candidate may withdraw their own application.
- Only authorized `OWNER`/`RECRUITER` members of the owning verified company may process the application.
- `VIEWER` is read-only.
- Preserve immutable status history with the actual human actor, timestamp, source and optional reason/note.
- Notify the candidate for meaningful company status changes and withdrawal confirmation.
- Keep applicant data private; companies may read applications only for their own opportunities.

### No reapplication after withdrawal

**A candidate may apply only once to a given opportunity.**

After an application reaches `WITHDRAWN`, the same candidate cannot submit another application for that same opportunity, even if the opportunity is still open. Retain the original withdrawn application and its history. Do not create a second application row.

Prevent duplicate and concurrent submissions at database level.

---

## 6. TRAINING registration workflow

TRAINING is not a job application.

- Training uses a direct registration workflow.
- No organizer approval is required in the initial product workflow.
- Registration is immediately confirmed when a seat is available.
- A full training programme accepts a waitlist registration only when waitlisting is enabled.
- Registration opening/closing windows and opportunity active state are enforced server-side.
- Cancellation is available to the participant while policy permits.
- Cancellation and registration must be transactional and concurrency-safe.

### FIFO waitlist with automatic promotion

**Waitlist order is first-in, first-out.**

When a confirmed participant cancels and a seat becomes available:

1. Lock/reconcile the training capacity state transactionally.
2. Select the oldest eligible `WAITLISTED` participant.
3. Promote that participant to `REGISTERED` automatically.
4. Update capacity counters and audit history atomically.
5. Send the promoted participant an in-app notification.
6. Repeat only while there are free seats and eligible waitlisted participants.

Use a deterministic tie-breaker (registration creation timestamp followed by stable row ID). Do not allow an organizer or client to bypass FIFO ordering.

Waitlisted participants do not consume confirmed capacity. A cancellation by a waitlisted participant does not create a seat. Do not promote anyone when the programme is cancelled/closed or its registration rules no longer permit participation.

All counts must reconcile to the authoritative registration rows; never trust client-supplied counts.

A participant may cancel a registration and, while registration remains open and rules permit, register again using the same logical registration record; do not create duplicate registration rows.

---

## 7. CV requirements

- CV is **optional by default** for JOB and INTERNSHIP applications.
- A verified company may mark the CV as required for a specific JOB or INTERNSHIP opportunity.
- When required, the server must reject an application without a valid CV owned by the candidate.
- When optional, an application may proceed without a CV.
- A user can attach only their own CV.
- Never expose CV bytes or private storage paths to another candidate or unrelated company.
- Training registration does not require a CV by default.
- Deleting/replacing CV metadata must not orphan private Storage objects. Cleanup must be server-controlled, idempotent and retryable; account deletion must also clean every user-owned CV object.
- Preserve audit and ownership checks around uploads, parse operations, replacement and deletion.

---

## 8. Recommendations and opportunity availability

- Recommendations are advisory, not proof of eligibility.
- The server must revalidate all eligibility and availability rules at the final application/registration operation.
- Hard eligibility and active-type filters run before ranking.
- Only `JOB`, `INTERNSHIP` and `TRAINING` can be active recommendation candidates.
- Excluded, unknown, cancelled, closed, expired or otherwise non-actionable opportunities must not be returned as actionable recommendations.
- JOB and INTERNSHIP use application eligibility and deadlines, not training capacity.
- TRAINING uses registration windows, capacity and waitlist state.
- Fresh and cached recommendations must follow identical rules.
- Any change that affects matching or availability must invalidate relevant cache entries.
- An upcoming training registration may be shown with an explicit upcoming state, but the UI must not imply it can be joined immediately.
- A full training programme without a waitlist must not be returned as actionable.
- A full training programme with FIFO waitlist may be returned as waitlist-only.

Use the current deterministic/free-first matching architecture unless a separately approved technical change is necessary. Do not introduce paid AI providers or transmit CV data to external AI services without approval.

---

## 9. Social Feed and out-of-scope boundaries

The Social Feed remains a core community capability and must not regress while implementing identity and career work.

Preserve existing privacy, ownership, reporting, moderation and rate-limit controls. New human/organization identity work must not accidentally grant users the ability to publish as an organization without verified membership.

The following remain out of scope:
- Scholarships.
- Competitions.
- Tuition, fees, instalments, financial aid and fee exemptions.
- Lectures, exams and academic course-content management.
- Standalone EVENT, CONFERENCE and VOLUNTEER opportunity catalogues.

---

## 10. Delivery and engineering rules

- No direct changes or commits to `main`.
- No merge or auto-merge without the owner's explicit approval.
- No force-push or destructive history rewrite.
- No production Supabase mutation, migration, deployment, deletion or credential rotation without explicit authorization.
- Use disposable local Supabase for database and integration testing.
- No real National IDs, real student records or personal phone numbers in fixtures/CI.
- Migrations are forward-only; never rewrite historical migrations.
- API, SQL, TypeScript, RLS, seeds, fixtures, OpenAPI and Android docs must express the same approved behavior.
- A mock proves only the adapter/test behavior; it does not prove a real external integration.
- Do not ask the product owner to reconfirm any decision in this document. Record technical decisions and proceed.

---

## 11. External dependencies — only items that may remain externally blocked

These are dependencies, not undecided product rules:

| Dependency | Required to claim real integration | What can proceed without it |
|---|---|---|
| Institution authoritative identity source | Approved API/database contract, authorized test access and credentials | Provider interface, validation, state model, mock, synthetic tests, onboarding orchestration |
| SMS delivery provider | Supabase-supported provider configuration, credentials/sender approval and delivery test | Auth flow, OTP lifecycle tests with local mock, rate limiting, API contracts |
| Company verification evidence | A documented checklist of acceptable evidence and an authorized admin reviewer | Company submission, pending/review/reject/verify state machine, audit log, test fixtures |
| Production Supabase release access | Explicit owner authorization, target environment and release credentials | Local migrations, CI, deployment/runbook design, rollback rehearsal plan |

Do not stop independent implementation because one external dependency is missing. Mark only the real integration as externally blocked, document the exact evidence needed, and continue the rest of the phases.

---

## 12. Decision status

All product decisions described in this document are **FINAL** as of 2026-11-26. No product-scope or business-rule clarification is pending for the three execution phases covered by the Master Execution Prompt.
