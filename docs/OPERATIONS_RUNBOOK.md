# Backend release and operations runbook

This document describes a controlled process only. It does not authorize deployment, Cloud project linking, resets, migrations or writes. No production credentials are stored in this repository.

## Environment boundaries

**Local disposable environment:** developer Supabase CLI stack and CI runner. Synthetic fixtures, local-only Auth Admin provisioning and local platform-admin demo grants are allowed. The synthetic university seed requires API localhost:54321 and DB localhost:54322 and must never target hosted infrastructure.

**Staging:** use a separate Supabase project and separate credentials, only after explicit owner approval. Do not import local synthetic administrator grants or synthetic phone accounts. Use isolated non-production provider credentials. Institutional identity and SMS integrations remain BLOCKED_EXTERNAL until real contracts and credentials are supplied.

**Production:** use production-specific secrets in protected environment secret storage. Never commit .env files, service-role keys, database passwords, provider secrets or DEMO_PASSWORD. No local fixture provisioning, no synthetic admin grants and no shared credentials.

## Protected secrets and access

Use least-privilege environment-scoped secrets. Service-role keys must be server-side only. Rotate credentials after exposure and restrict Actions environments/approvers. Never log Authorization headers, OTPs, passwords, raw National IDs or CV contents. The local synthetic runner reads DEMO_PASSWORD from the process environment and never writes it to fixtures or SQL.

## Migration rehearsal

1. Review every forward-only migration and its rollback implications.
2. Take a verified backup of the target environment and record the restore point.
3. Rehearse against an isolated staging clone with representative schema and data volume.
4. Validate migration order, constraints, grants, RLS, triggers, RPCs and Edge Function compatibility.
5. Verify mobile/API contract compatibility and monitor query plans and locks.
6. Obtain explicit owner approval before scheduling any production change.
7. Apply migrations through the approved controlled workflow only; never use local university fixture seeds in hosted environments.

Migrations are forward-only. A rollback is normally a new compensating migration or restore from the verified backup, not editing a historical migration.

## Backup and restore

Use the Supabase-supported backup/export capability appropriate to the project's plan and database size. Verify encryption, retention, access controls and completion. Periodically test restore into an isolated project; a backup that has not been restored is not a verified recovery plan. Include Storage objects and metadata consistency, especially CV cleanup queue state.

## Rollback and incident response

Define a release owner, incident commander and escalation contacts before rollout. On a failed release, stop further rollout, preserve logs and timestamps, assess data integrity, and choose either a tested compensating migration or restore point. Do not delete the CV cleanup queue to silence alerts. For suspected secret exposure, revoke/rotate the key first, review access logs, then investigate scope. For Auth/OTP issues, disable the affected integration rather than silently falling back to mock verification.

## Health checks and monitoring

Monitor database availability, migration state, elevated error rates, Auth/OTP delivery, Edge Function latency/errors, rate-limit failures, RLS-denied access anomalies, Storage deletion backlog and exhausted CV cleanup attempts. Reconcile `private.cv_cleanup_queue` pending/processing/failed/done/exhausted counts and investigate expired leases or repeated failures. Alert on unusual admin grants, verification-source changes and account lifecycle actions.

## Go/no-go criteria

Do not declare a release ready until migrations apply cleanly, all pgTAP/RLS and concurrency suites pass, all local HTTP integrations pass, OpenAPI and mobile contract checks pass, and QA has retested the current Builder HEAD. A failed pgTAP run blocks concurrency and HTTP evidence; never infer those steps passed.
