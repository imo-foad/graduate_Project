# MASTER EXECUTION PROMPT — ALUMNI CONNECT
## Autonomous delivery of Phases 1–3
### Final product decisions | End-to-end execution | External dependency isolation | Strict security and testing | Manual merge only

---

# 0. EXECUTION DIRECTIVE

You are the autonomous engineering team responsible for completing the first three backend phases of **Alumni Connect**.

Repository:

`https://github.com/imo-foad/graduate_Project`

Authoritative product decisions:

`docs/PRODUCT_DECISIONS.md`

**Read that document before making any product or architecture decision. Its decisions are final and must not be re-asked.**

The owner has explicitly approved all nine decisions below:

1. Opportunity scope: `JOB`, `INTERNSHIP`, `TRAINING` only.
2. Phone OTP: required during registration.
3. Human identities: one account may hold multiple institution-verified identities.
4. Company publishing: company must be verified first.
5. Internship workflow: same application lifecycle as JOB.
6. Training workflow: direct registration, no organizer approval.
7. CV: optional by default; may be required per JOB/INTERNSHIP opportunity.
8. Waitlist: FIFO with automatic promotion after a confirmed seat is released.
9. Reapply after withdrawal: prohibited for the same opportunity.

Do not ask the owner to repeat, reconfirm or choose among these decisions.

Your job is to discover the repository, implement the approved behavior, test it, document it and report genuine external dependencies. Do not stop after every phase merely to ask whether you may continue.

**Autonomy requirement:** Execute Phase 1, then Phase 2, then Phase 3 in sequence without a product-decision approval pause between them. If one external integration is unavailable, implement and test its interface/mock, mark the real integration as externally blocked, and continue every independent task.

The only actions that remain prohibited without explicit owner authorization are:
- merging a pull request,
- modifying `main`,
- production Supabase mutations/deployment,
- force-pushing or destructive history changes,
- or using real sensitive identity data.

---

# 1. SOURCE OF TRUTH AND FINAL BUSINESS RULES

`docs/PRODUCT_DECISIONS.md` is the authoritative business source. If it is not yet merged into `main`, read it from branch:

`docs/final-product-decisions-and-autonomous-plan`

Do not wait for that documentation PR to merge before starting independent work. Do not create a conflicting copy.

## 1.1 Active product scope

Active opportunity types are exactly:

- `JOB`
- `INTERNSHIP`
- `TRAINING`

Not active:
- `EVENT`
- `CONFERENCE`
- `VOLUNTEER`
- `SCHOLARSHIP`
- `COMPETITION`

Historical rows are preserved; excluded types must not be newly created, reactivated, discovered, recommended, applied to or registered for.

Do not rewrite old migrations. Use a new forward-only migration.

## 1.2 Authentication and identity

Registration:
- National ID + phone + password.
- Verify National ID against the institution's authoritative data source.
- Verify phone ownership with mandatory OTP before activating the human account.

Login:
- Phone number + password only.
- National ID is never a login credential.
- No fake email aliases.

Human identities:
- STUDENT, GRADUATE, FACULTY.
- One Auth account may hold multiple trusted institutional identities.
- Identity attributes come from the institution provider, never from a client role field.

Organizations:
- Separate company/institution/organization identities with individual authenticated human members.
- Company publishing requires VERIFIED company status.
- Minimum company roles: OWNER, RECRUITER, VIEWER.

Sensitive identifiers:
- Never log or expose National ID.
- Use a protected storage/lookup design if persistence is necessary.
- Synthetic values only in tests.

## 1.3 Career workflows

JOB and INTERNSHIP share the same application lifecycle and permissions.

Application transition graph:
- SUBMITTED -> UNDER_REVIEW, REJECTED, WITHDRAWN
- UNDER_REVIEW -> SHORTLISTED, REJECTED, WITHDRAWN
- SHORTLISTED -> INTERVIEW, REJECTED, WITHDRAWN
- INTERVIEW -> ACCEPTED, REJECTED, WITHDRAWN
- ACCEPTED, REJECTED and WITHDRAWN are terminal.

No reapplication to the same opportunity after WITHDRAWN.

TRAINING uses direct registration, no organizer approval, capacity and FIFO waitlist. When a confirmed registrant cancels, promote the oldest eligible waitlisted registrant atomically and notify them.

CV is optional by default; a verified company can make it mandatory per JOB/INTERNSHIP.

Recommendations must apply active-type, eligibility, deadline and availability rules consistently across fresh and cached results. Final submission/registration always revalidates on the server.

## 1.4 Product areas to preserve

Social Feed remains a core product capability. Preserve its existing implementation, privacy, moderation, ownership and rate-limit controls. Do not regress it while expanding account identities.

Financial and academic administration features remain out of scope.

---

# 2. REPOSITORY BASELINE AND CURRENT KNOWN STATE

Start by fetching the latest remote state. Do not trust stale local branches or old audit reports.

Known last verified state (recheck before acting):
- `main` was at `17be1b305481fa1441bc3c817dcbe5cef6e75ac6` after PR #37.
- PR #38 was open on `fix/scope-foundation-parity` at `87f5e8a1ccb0481a94cbcdbc0b0c7213d3009b0d`.
- PR #38's CI run #584 was green: 134/134 TypeScript tests, 22/22 OpenAPI checks, 14/14 workflow lint checks, 498 pgTAP assertions across 14 files, local concurrency checks, local integration journeys and two uploaded artifacts.
- PR #38 mirrors the then-current SQL list of six types. That six-type list is no longer the approved product scope. Do not merge PR #38 unchanged or describe its six values as final.
- No production Supabase validation is implied by local CI.
- PR #33 contains an old onboarding branch with changes partly superseded by main; its old test runner references cancelled Scholarship/Competition suites and must not be merged blindly.
- PR #7 is an old one-file CV test change based on an obsolete baseline.
- PR #2's code is already ancestral to the integrated main history; verify ancestry and unique content before deciding it is redundant.

Use these facts as navigation hints only. Verify all current refs, PRs, Issues, commits and tests.

---

# 3. AUTONOMOUS EXECUTION RULES

## 3.1 One execution branch, phase checkpoints, no main writes

- Fetch latest `origin/main`.
- Create one long-running feature branch from the exact current main SHA, for example `feat/first-three-phases-autonomous`.
- Keep Phase 1, Phase 2 and Phase 3 in clearly separated commits/checkpoints within this branch.
- Do not push or commit to `main`.
- Do not merge.
- Do not enable auto-merge.
- Do not force-push.
- Do not delete user branches.
- Open one comprehensive PR to `main` after the three phases have been executed and tested, unless a genuine technical/security blocker makes that impossible. If blocked, open a PR only for independently completed, safe work and continue on the same feature branch.

This structure intentionally removes the need to wait for a merge between phases. The owner reviews and manually merges when ready.

## 3.2 Work without repeated owner questions

The product rules are final. Do not ask questions about:
- active opportunity types,
- OTP requirement,
- multiple human identities,
- company verification,
- Internship behavior,
- Training behavior,
- CV optionality,
- FIFO waitlist,
- or reapplication after withdrawal.

For technical choices:
- inspect current architecture,
- select the safest maintainable option,
- document why,
- add tests,
- proceed.

For missing external inputs:
- build the adapter/interface and a deterministic local mock,
- add contract and failure/retry tests,
- write an external dependency record with the exact missing artifact/access,
- mark the real provider integration as BLOCKED_EXTERNAL,
- continue every independent task.

Ask no broad clarification questions. Do not stop the execution because one dependency is absent.

## 3.3 Repository safety and environment verification

Inspect:
```bash
git status --short --branch
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -20
git remote -v
git fetch origin
```

Preserve uncommitted user work. Never overwrite unknown changes.

All database and HTTP tests use disposable local Supabase only.

Never:
- link/reset/migrate/deploy to Supabase Cloud,
- delete production records/users/storage,
- change production Auth settings,
- deploy or delete production Edge Functions,
- expose service-role keys,
- use real National IDs, phone numbers or student records in CI.

## 3.4 Migration and security discipline

- Historical migrations are immutable.
- Add forward-only migrations after checking the highest applied/versioned migration. The current known latest is 0025; use the next free number only after rechecking.
- Preserve history and foreign keys.
- Document backfill, idempotency, migration failure and rollback/recovery considerations.
- RLS and server-side authorization are mandatory; UI checks are not security.
- Every service-role operation must be narrowly scoped and server-side.
- Protect cross-company isolation, candidate privacy, sensitive identifiers, OTP abuse, rate limits, replay and concurrency.
- Never log secrets or full National IDs.

## 3.5 Evidence discipline

Never call a mocked integration real.
Never call a local test production evidence.
Never call compilation a functional test.
Never report exact counts unless present in real output.

Report:
- passed,
- failed,
- skipped,
- not run,
- blocked by external access.

---

# PHASE 1 — SCOPE ALIGNMENT, BASELINE AND TECHNICAL FOUNDATION

## Objective

Bring the current repository into alignment with the approved three-type scope and verify/repair the backend foundation before expanding identity and career behavior.

## 1.1 Full baseline audit

Inspect:
- all migrations,
- all SQL functions/triggers/constraints,
- RLS and grants,
- Auth configuration and account lifecycle,
- Edge Functions and shared modules,
- company identities and memberships,
- opportunity/application/registration workflows,
- CV storage and parsing,
- recommendation/scoring/cache,
- Social Feed and moderation,
- OpenAPI,
- Android integration docs,
- README and audit report,
- seed/fixtures,
- CI scripts and all test suites,
- open Issues and pull requests.

Produce an implementation matrix: IMPLEMENTED, PARTIAL, MISSING, EXTERNAL, or UNVERIFIED.

Historical migrations are not active product requirements.

## 1.2 Reconcile PR #38 with final core scope

PR #38's original code mirrors six values because that was the SQL allow-list when it was created. The owner has now approved only three.

Do not accept/merge PR #38 unchanged.

Inspect its branch and either revise it or supersede it safely so the end state is:

```ts
["JOB", "INTERNSHIP", "TRAINING"]
```

and SQL `public.is_opportunity_type_active` returns true for exactly those three values.

Because SQL currently allows more values, a forward-only migration is now required. Do not rewrite migration 0025 or any older migration.

The migration must:
- tighten the SQL active-type helper to exactly the three approved types,
- keep unknown/case-variant/whitespace values rejected,
- block new creation/reactivation of EVENT, CONFERENCE, VOLUNTEER, SCHOLARSHIP and COMPETITION,
- preserve historical data,
- safely deactivate existing excluded opportunities from active discovery,
- prevent new registrations/applications for excluded types,
- exclude those types from recommendation candidate projection, scoring, fresh output and cached output,
- preserve historical application and registration records,
- avoid deleting old tables or migrations.

Update all relevant TypeScript, SQL, constraints/triggers, validators, OpenAPI enums, seed builders, fixtures, docs and tests to the exact same core allow-list.

Search all code paths for:
- EVENT
- CONFERENCE
- VOLUNTEER
- SCHOLARSHIP
- COMPETITION
- type-specific RPC guards
- scoring weights
- training/registration mapping
- recommendation candidate queries.

Do not confuse old event-oriented technical table names with active product types. If `event_registrations` remains the safe existing table for TRAINING registration, it may remain as a legacy technical name while the public/API/business contract describes TRAINING correctly.

## 1.3 Issue/PR disposition

Inspect current content and commit ancestry before closing or retargeting anything.

### PR #33
- Compare its head against the current main, not its old base.
- Reuse only unique onboarding test improvements that are compatible with final product decisions.
- Do not reintroduce Scholarship/Competition test files or old 16-file pgTAP expectations.
- Verify its migration 0023 and onboarding pgTAP change are already integrated before treating them as new work.
- If unique changes are useful, port only those onto the execution branch and add current tests.
- Do not merge PR #33 blindly.

### PR #7
- Compare the exact changed test against current main.
- Determine whether it contains any executable assertion or only obsolete commentary/contract wording.
- If superseded or no longer useful, record why and close as redundant/obsolete when safe.

### PR #2
- Verify whether its head commit is an ancestor of current main.
- Inspect every path that differs and confirm no unique code is missing.
- If fully integrated and no unique changes remain, close as already integrated/superseded. Do not merge an old PR that targets backend-initial-import.

Do not close PRs or Issues merely to make the board look clean; provide evidence and use the correct closure reason.

## 1.4 Issue verification

### #14 and #15
Scholarships and Competitions are cancelled. Verify scope guard and then close as NOT_PLANNED, preserving the historical explanation.

### #16 — recommendation availability
Verify the current migration 0024 implementation, the TypeScript scoring/filter logic, cache invalidation, and the final TRAINING behavior. Add tests for:
- open training,
- upcoming training,
- full without waitlist,
- full with waitlist,
- cancelled/closed training,
- capacity released by cancellation,
- fresh vs cached consistency.

Close only when the final core TRAINING behavior is proved. Do not base acceptance on old EVENT-only tests.

### #18 — CV Storage cleanup
The account-deletion Edge Function has logic to enumerate and delete all CV objects under a user prefix, but ordinary metadata deletion may still leave orphaned files. Verify the full lifecycle:
- individual CV metadata deletion,
- replacement,
- upload succeeds but metadata insert fails,
- parse failure,
- account deletion,
- retry after Storage error.

Route deletion/replacement through a server-owned idempotent cleanup mechanism or durable cleanup queue. Do not rely on a client deleting Storage and metadata separately. Add reconciliation evidence for orphaned objects. Close only when all applicable paths are tested.

### #20 — documentation freshness
Update README, AUDIT_REPORT, OpenAPI and Android contract to match current main plus this approved scope. Historical audit snapshots may remain, but must be labelled historical and must not appear to describe current state. Close only after a consistency check.

### #21 — CI diagnostics artifacts
Verify the current workflow sets `include-hidden-files: true` for `.ci-logs/` and a current green workflow actually uploads a non-empty `database-test-logs` artifact. If proven, close as completed.

### #23 — Internship and Training assumptions
The business decisions are now final:
- Internship is same workflow as JOB.
- Training is direct registration, no approval, capacity + FIFO waitlist.
Implement and test them in Phase 3. Close only after implementation evidence.

### #24 — CV extraction evaluation
Do not block the first three phases on a real representative CV corpus. Keep synthetic tests. Record a separate evaluation limitation; never claim synthetic cohort accuracy proves real-world accuracy. Do not add OCR or paid parsing unless a technical case and approved provider access exist.

Review #17 social moderation as a preserve/regression requirement. Social Feed must not regress.

## 1.5 Phase 1 tests and deliverables

Run:
- TypeScript unit suite,
- SQL lint/static checks,
- OpenAPI contract,
- workflow lint,
- clean disposable local migration apply,
- all current pgTAP files,
- RLS/grant checks,
- concurrency checks,
- local HTTP integration,
- onboarding and CV lifecycle integration,
- rate-limit integration,
- recommendation and career-cohort tests.

Deliver:
- current repository audit,
- final active-type consistency proof,
- forward migration and tests,
- repaired/updated PR/Issue disposition,
- current documentation,
- exact CI evidence,
- one Phase 1 checkpoint commit.

Do not stop; continue to Phase 2.

---

# PHASE 2 — VERIFIED HUMAN IDENTITY, AUTH AND ORGANIZATION ONBOARDING

## Objective

Implement the approved National-ID + phone/password + mandatory phone OTP onboarding architecture, with one human account and multiple verified institutional identities, plus secure organization memberships.

## 2.1 Inspect and reuse

Inspect existing:
- `auth.users`,
- `profiles`,
- `graduate_profiles`,
- company and membership tables,
- invitation flows,
- admin controls,
- account status/suspension,
- Auth triggers,
- Edge Functions,
- JWT and RLS policies,
- bootstrap scripts.

Do not duplicate account tables or create a separate Auth user for each role.

## 2.2 Identity model

Implement one authenticated human account with multiple verified identity/affiliation records:
- STUDENT,
- GRADUATE,
- FACULTY.

The authoritative institutional provider determines the identities and their attributes.

Support identity lifecycle changes without losing the underlying account, history or ownership.

Reject any attempt to self-assign a role via:
- request JSON,
- user-editable profile fields,
- untrusted JWT metadata,
- client-side state.

Authorization must use trusted server/database records.

## 2.3 Registration orchestration

Implement a secure sequence consistent with currently supported Supabase Auth:

1. Validate National ID, phone and password.
2. Normalize the phone number consistently.
3. Call the institution identity provider adapter.
4. Reject no-match and invalid identity results safely.
5. Resolve the authoritative human identities/attributes.
6. Check duplicate National ID/phone/account conflicts.
7. Create or initiate the Supabase phone/password signup flow.
8. Require OTP verification and confirm phone ownership.
9. Create/activate the human profile and verified identity records only at the correct trusted point in the lifecycle.
10. Record an audit event without exposing the National ID.
11. Make retry/idempotency and partial-failure recovery safe.

Validate Supabase's current supported signup/OTP behavior before choosing exact call ordering.

Do not leave an active profile with unverified identity or unverified phone.

Handle:
- provider success + Auth failure,
- Auth success + OTP timeout,
- OTP retry/expiry,
- duplicate concurrent requests,
- phone already bound to another account,
- identity already linked to another account,
- provider timeout/unavailability,
- client retries after network loss.

Use transactions, unique constraints, idempotency keys and a recoverable pending state as appropriate.

## 2.4 External provider boundary

Create an explicit `IdentityVerificationProvider`-style abstraction with:
- normalized result states,
- timeout,
- bounded retry,
- idempotency,
- typed errors,
- audit outcome,
- safe logging,
- test mock.

Do not invent the institution API, schema, credentials or source records.

The real National ID integration is BLOCKED_EXTERNAL until the institution provides an approved contract and authorized test access. Continue the rest of the implementation.

## 2.5 Phone OTP

OTP is required for registration.

- Use Supabase-supported phone verification and approved SMS provider.
- Protect from OTP spam, brute force and replay.
- Normalize and uniquely associate phone numbers.
- Do not log OTP values.
- Never claim SMS integration is live if the provider configuration is missing.
- Local mocks are test-only.

The actual SMS delivery provider configuration remains BLOCKED_EXTERNAL until credentials/sender authorization and a real delivery test are supplied.

Login remains phone/password only; National ID is not a login identifier.

Implement supported password recovery, phone change and session lifecycle safely. Phone changes require proving control of the new number and must not permit account takeover.

## 2.6 Organization onboarding and verification

Reuse company tables/memberships where sound.

Implement or complete:
- company creation,
- owner/member management,
- invitations,
- accepted/expired/revoked invitations,
- OWNER/RECRUITER/VIEWER permissions,
- ownership transfer,
- manual verification submission/review,
- rejection/resubmission,
- suspension/reactivation,
- audit history.

Only verified companies publish JOB/INTERNSHIP. A suspended/rejected/pending company cannot publish.

Only authorized admins can verify. Admin bootstrap is out-of-band, auditable and never public.

The approved evidence checklist may be stored/configured for admin review; do not invent external registry APIs. If the owner has not provided an evidence checklist, implement an auditable manual review process with a configurable evidence list and mark the policy configuration as operational input, not a blocker for the technical workflow.

Every action records both organization ID and actual human actor.

## 2.7 Phase 2 security and test matrix

Identity:
- verified National ID match,
- no-match,
- duplicate identity,
- invalid input,
- provider unavailable/timeout/malformed response,
- retry/idempotency,
- no raw National ID in logs/responses/JWT.

Auth:
- phone/password signup,
- OTP required and success,
- invalid/expired/replayed OTP,
- duplicate phone,
- login with phone/password,
- National ID login rejected/not offered,
- password recovery,
- phone change,
- session refresh/logout,
- account suspension.

Multi-identity:
- one user with Student + Graduate or Graduate + Faculty where mock data authorizes it,
- role transitions,
- untrusted role injection rejected,
- no user can promote themselves.

Organization:
- owner/recruiter/viewer permissions,
- invite lifecycle,
- verified publication gate,
- pending/rejected/suspended publication blocked,
- cross-company data isolation,
- admin-only review,
- ownership transfer,
- audit actor correctness.

Concurrency:
- two registrations for the same identity,
- two users claim same phone,
- duplicate invitation acceptance,
- concurrent owner changes,
- OTP request abuse.

Use only synthetic data.

## 2.8 Phase 2 deliverables

- identity architecture and ERD,
- verified onboarding flow,
- Auth implementation/configuration,
- provider abstraction and mock,
- multiple verified identity/affiliation model,
- phone OTP flow,
- organization membership and verification workflow,
- secure admin bootstrap runbook,
- migrations,
- RLS/grants,
- Edge Functions/RPCs,
- OpenAPI and Android contract,
- tests and evidence,
- external dependency register,
- Phase 2 checkpoint commit.

Do not stop; continue to Phase 3.

---

# PHASE 3 — JOB, INTERNSHIP AND TRAINING CAREER WORKFLOWS

## Objective

Deliver a complete and secure opportunity lifecycle for the approved three opportunity types.

## 3.1 Opportunity publication

Only verified company members with OWNER or RECRUITER permissions may create/manage company JOB/INTERNSHIP opportunities.

Implement:
- draft creation,
- validation,
- editing,
- publication,
- closing,
- expiry/deadline behavior,
- company suspension effects,
- audit actor,
- in-app notifications where relevant.

Viewer is read-only.

Do not permit client-supplied company IDs to bypass membership checks.

TRAINING may be published only by an authorized verified company or approved training organizer identity. Apply equivalent authorization and verification rules.

Use the opportunity type as the source of truth:
- JOB,
- INTERNSHIP,
- TRAINING.

Do not create active EVENT/CONFERENCE/VOLUNTEER types.

## 3.2 Opportunity validation

Inspect current schema first. Add only needed fields.

Validate by type:
- JOB and INTERNSHIP share job/application fields and flow.
- TRAINING uses registration window, capacity, waitlist and training information.
- No capacity semantics for JOB/INTERNSHIP unless a specific business need is evidenced.
- Include title, description, organization, location/attendance mode, skills, eligibility, deadline, publication dates and type-specific information only where appropriate.

Do not add redundant fields or duplicate values across tables.

## 3.3 Job and Internship applications

Both opportunity types use the same lifecycle and application operation.

The current implementation's JOB-only guard is obsolete under the approved decision. Update it so both JOB and INTERNSHIP can be applied for using the same state machine.

Enforce:
- candidate owns the application,
- correct active type,
- open opportunity and deadline,
- eligibility requirements,
- optional/required CV policy,
- no duplicate application,
- concurrency-safe unique constraint,
- private candidate data,
- company membership authorization.

No reapplication is allowed after WITHDRAWN. Keep the original application and history.

The state graph is strict:

```text
SUBMITTED -> UNDER_REVIEW
SUBMITTED -> REJECTED
SUBMITTED -> WITHDRAWN

UNDER_REVIEW -> SHORTLISTED
UNDER_REVIEW -> REJECTED
UNDER_REVIEW -> WITHDRAWN

SHORTLISTED -> INTERVIEW
SHORTLISTED -> REJECTED
SHORTLISTED -> WITHDRAWN

INTERVIEW -> ACCEPTED
INTERVIEW -> REJECTED
INTERVIEW -> WITHDRAWN
```

No transitions out of ACCEPTED, REJECTED or WITHDRAWN.

Validate the exact current status constraints and all functions. Prevent direct client writes from bypassing the transition RPC.

Record:
- prior/new state,
- actual actor,
- actor's company membership at action time,
- timestamp,
- optional note/reason,
- notification event.

Do not allow a company to inspect another company's applications or a candidate's private CV.

## 3.4 CV requirement

CV optional by default.

Add a per-opportunity required flag for JOB/INTERNSHIP if the schema lacks it. Only authorized company OWNER/RECRUITER may change it, preferably while draft or through a controlled rule.

Server enforcement:
- required + no valid owned CV -> reject.
- optional + no CV -> allow.
- supplied foreign CV -> reject.
- deleted/inactive/invalid CV -> reject as appropriate.

Training registration does not require CV by default.

Resolve Issue #18's orphaned Storage object lifecycle with idempotent server-owned deletion/replacement and retry/reconciliation.

## 3.5 Training direct registration

TRAINING is direct registration; organizer approval is not required.

Use the registration window, active state and capacity.

States:
- REGISTERED
- WAITLISTED
- CANCELLED

If capacity remains, registration becomes REGISTERED.
If full and FIFO waitlist is enabled, registration becomes WAITLISTED.
If full and waitlist is disabled, reject with a precise capacity error.
Reject before registration opens or after the allowed registration close/deadline.

Participant can cancel while allowed.

No duplicate registration records.

## 3.6 FIFO waitlist auto-promotion

Implement automatic FIFO promotion in the same database transaction that frees a confirmed seat.

Requirements:
- order by original waitlist timestamp, stable ID tiebreaker,
- lock training opportunity/capacity state,
- lock/select earliest eligible waitlisted row,
- promote to REGISTERED,
- update count atomically,
- write history/audit,
- emit exactly one in-app notification,
- promote multiple people when multiple seats are released,
- do not promote when training is cancelled/closed or registration is no longer allowed,
- ensure retries are idempotent,
- do not trust client-maintained counts.

Add real concurrency tests where several users contend for the last slot and several cancellation/promotion operations race.

## 3.7 Recommendation and availability alignment

Only JOB, INTERNSHIP, TRAINING can enter discovery/scoring.

For JOB/INTERNSHIP:
- validate active/published state,
- deadline,
- eligibility,
- skills/experience requirements,
- company verified status.

For TRAINING:
- validate active state,
- registration start/end,
- available capacity,
- waitlist availability.

Fresh and cached rows must be filtered identically.

Changing:
- active type,
- status,
- deadline,
- registration window,
- capacity,
- registered count,
- waitlist state,
- skills/eligibility,
must invalidate or revalidate relevant cache.

Hard eligibility is applied before ranking. A high similarity score cannot override ineligibility.

Recommendations are not permission to apply; final RPC revalidates.

Keep deterministic/free-first scoring unless a technical requirement proves otherwise. No unapproved paid AI.

## 3.8 Notifications

Use current in-app notification architecture.

Notify:
- candidate on application state change,
- candidate on withdrawal confirmation,
- training participant on registration confirmation/cancellation,
- promoted waitlisted participant when confirmed,
- authorized company members for appropriate career workflow changes.

No duplicate notifications on retries.

Do not claim push notifications unless configured separately.

## 3.9 Phase 3 tests

Publication:
- owner/recruiter create/publish,
- viewer blocked,
- unverified/suspended company blocked,
- invalid fields rejected,
- cross-company publishing blocked,
- unauthorized edits/status changes blocked.

Applications:
- JOB apply,
- INTERNSHIP apply through same operation,
- eligibility failure,
- required CV enforcement,
- optional CV omission,
- foreign CV rejected,
- duplicate application rejected,
- withdrawn reapplication rejected,
- each allowed state transition,
- each forbidden/skipped/reopened transition,
- company/candidate privacy,
- concurrent duplicate submissions.

Training:
- direct registration,
- before-open rejection,
- after-close rejection,
- one available slot,
- full/no-waitlist rejection,
- full/waitlist registration,
- FIFO ordering,
- automatic promotion after cancellation,
- multiple-seat promotion,
- cancellation by waitlisted user,
- repeated cancellation,
- duplicate registration,
- concurrency on final slot,
- counter reconciliation,
- exactly-once notification behavior.

Recommendations:
- only three approved types,
- excluded/unknown types never returned,
- JOB/INTERNSHIP application eligibility,
- TRAINING upcoming/open/full/waitlist behavior,
- fresh/cache parity,
- cache invalidation after capacity and type changes,
- ineligible item never appears as actionable.

Run all legacy regression tests including Social Feed, moderation, RLS and rate limiting.

## 3.10 Phase 3 deliverables

- opportunity/business lifecycle documentation,
- JOB/INTERNSHIP shared application flow,
- strict application state machine,
- CV policy and cleanup,
- TRAINING direct registration,
- FIFO auto-promotion,
- publication and organization authorization,
- recommendation/availability alignment,
- notifications and audit,
- migrations and server functions,
- OpenAPI and Android integration contract,
- full regression/security/concurrency evidence,
- Phase 3 checkpoint commit.

---

# 4. TESTING AND QUALITY GATES

Every phase must include:
- TypeScript unit tests,
- SQL static/lint checks,
- OpenAPI contract tests,
- workflow lint,
- clean local migration replay,
- all pgTAP files,
- RLS and grants,
- local HTTP integration,
- concurrency,
- failure/retry/idempotency,
- rate limits,
- regression tests.

No happy-path-only testing.

For every feature, test:
- success,
- invalid input,
- unauthenticated,
- unauthorized,
- duplicate,
- concurrent,
- expired/closed state,
- provider failure where applicable,
- retry,
- ownership isolation,
- notification/audit correctness.

A green suite cannot override a wrong business rule.

## Migration proof

1. Start a clean disposable local Supabase stack.
2. Apply all migrations in sequence.
3. Run synthetic seeds.
4. Run all pgTAP tests.
5. Run concurrency tests.
6. Run HTTP integrations.
7. Verify grants/RLS.
8. Capture exact logs and artifacts.
9. Ensure no Cloud URL/key was used.

Report exact counts from the real output.

---

# 5. DOCUMENTATION REQUIREMENTS

Keep these synchronized:
- `docs/PRODUCT_DECISIONS.md`
- `docs/MASTER_EXECUTION_PROMPT.md`
- `README.md`
- `docs/AUDIT_REPORT.md`
- `docs/openapi.yaml`
- `docs/ANDROID_INTEGRATION.md`

Mark old audit scores and test results as historical; never present them as current.

For each external dependency, maintain:
- provider/system,
- missing contract or access,
- implemented adapter,
- mock test evidence,
- what has not been verified,
- exact evidence needed to unblock production integration.

Do not ask the owner again for decisions in PRODUCT_DECISIONS.md.

---

# 6. FINAL PR AND REPORT

After Phase 1, Phase 2 and Phase 3 have been executed as far as technically possible:

1. Run the entire current test suite from a clean local Supabase environment.
2. Review the complete Git diff.
3. Perform a security review of all changed RLS, SQL, Edge Functions and Auth code.
4. Confirm API and documentation consistency.
5. Create one PR targeting `main`.
6. Do not merge it or enable auto-merge.

The PR must clearly separate the Phase 1, Phase 2 and Phase 3 commit/checkpoint history and include:
- summary,
- decisions implemented,
- files changed,
- migrations and data impact,
- security review,
- exact test evidence,
- external dependencies,
- remaining risks.

Return a detailed report in Egyptian Arabic:

## Overall result
- Completed / Partially completed / Blocked.
- Branch, base SHA, head SHA and PR URL.

## Phase 1
- Scope alignment,
- PR/Issue disposition,
- migration and tests,
- documentation status.

## Phase 2
- Identity model,
- phone/password + OTP,
- National ID provider adapter/mock,
- verified affiliations,
- organization authorization.

## Phase 3
- JOB/INTERNSHIP application flow,
- strict status graph,
- TRAINING registration,
- FIFO waitlist,
- CV policy,
- recommendations.

## Test evidence
Use actual numbers. Separate passed, failed, skipped, not run and externally blocked.

## External dependencies
List only real external inputs/access still missing. Do not ask broad product questions.

## Remaining risks
Separate blocking defects, non-blocking defects, external dependencies and technical debt.

## Readiness
Distinguish implementation completeness, test pass rate, test coverage and production readiness. Do not turn a green CI percentage into a product-completeness percentage.

## Manual owner action
State that the PR is ready for owner review/merge only if supported by evidence. Never merge it.

**Do not stop after Phase 1 or Phase 2 to request approval or product clarification. Continue the full approved scope. Stop only for the prohibited destructive/production actions or a genuine security/safety blocker; otherwise document the limitation and keep moving.**
