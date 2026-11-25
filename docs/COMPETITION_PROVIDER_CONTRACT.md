# Competition Organizer Provider Contract v1

## Purpose and status semantics

The Competition lifecycle separates an entry that has been saved inside Alumni Connect from an entry that the organizer has acknowledged. A competition remains internal unless a platform administrator explicitly configures a provider mapping. Sample opportunities can never be mapped to an external organizer.

The states have distinct meanings:

- `SUBMITTED`: saved to Alumni Connect only; it is not represented as delivered to an organizer.
- `PENDING_DELIVERY`: an organizer mapping exists and the outbox is waiting to send the entry.
- `SUBMITTED_EXTERNALLY`: the organizer returned a valid acceptance response and a non-empty external application reference.
- `IN_REVIEW`, `ACCEPTED`, `REJECTED`: subsequent reviewer or verified organizer callback decisions.
- `DELIVERY_FAILED`: automated delivery attempts were exhausted or a permanent provider error occurred. An authorized admin may initiate a new delivery generation.

## Provider configuration and secrets

The Edge Functions read the provider registry from `COMPETITION_PROVIDERS_JSON`. Secrets are not stored in Postgres, returned by RPCs, or exposed to Android.

Example:

```json
{
  "ORGANIZER_A": {
    "endpoint": "https://organizer.example.com/api/competition-entries",
    "bearer_token": "<secret>",
    "webhook_secret": "<secret>"
  }
}
```

The endpoint must use HTTPS and must not target a local/private host. A bearer token of at least 16 characters and HMAC webhook secret of at least 32 characters are required. Each listing is mapped to an organizer opportunity identifier by an active platform administrator.

## Outbound request

The worker claims entries from a private outbox and sends a JSON event:

```json
{
  "schema_version": "1.0",
  "event": "competition.application.submitted",
  "application_id": "platform UUID",
  "provider_opportunity_id": "organizer opportunity identifier",
  "submitted_at": "ISO-8601 timestamp",
  "applicant": {
    "full_name": "Applicant name",
    "email": "Applicant email"
  },
  "personal_statement": "Optional statement",
  "answers": {
    "project_title": "Entry title",
    "project_summary": "Organizer-defined answers"
  },
  "cv_download_url": "Short-lived signed URL or null"
}
```

The request uses `Authorization: Bearer ...`, `Idempotency-Key`, `X-Alumni-Timestamp`, and `X-Alumni-Signature`. The signature is HMAC-SHA256 over `timestamp + "." + raw JSON body`. The outbox UUID is the stable idempotency key for a delivery item.

The organizer must return a 2xx JSON response with `accepted: true` and a non-empty `application_reference`. An optional `request_id` is retained in the delivery audit. Only this acknowledgement allows the platform to mark the entry `SUBMITTED_EXTERNALLY`.

Network errors, HTTP 408/425/429 and 5xx are retryable; a valid `Retry-After` is respected within the bounded backoff. Permanent 4xx responses and malformed acknowledgements are not automatically retried. Repeated sends within the same generation retain the same idempotency key.

## Organizer callbacks

The organizer sends callbacks to `POST /functions/v1/competition-provider-callback`:

```json
{
  "provider_key": "ORGANIZER_A",
  "event_id": "organizer-unique-event-id",
  "application_reference": "organizer-reference",
  "status": "IN_REVIEW",
  "note": "Optional review note"
}
```

Callbacks carry the timestamp and HMAC signature headers. Requests outside the five-minute replay window, invalid signatures, unknown references, reused event IDs with changed payloads, and invalid transitions are rejected. Supported organizer updates are `IN_REVIEW`, `ACCEPTED`, and `REJECTED`. The platform records accepted unique events in a private idempotency ledger and creates status-history/notification records.

## Submission answers, teams and judging

The platform forwards the applicant identity, optional CV, personal statement, and the opportunity-specific `submission_data` JSON object. The backend validates the object shape and caps its serialized payload at 32 KiB. It does not assume every organizer uses the same application form.

Issue #15 did not provide an organizer API specification, team-size rules, member roles, mentor rules, judging rubric, scoring phases, or a canonical schema for teams. This implementation therefore does not invent a team/judging workflow. Such capabilities must be added against the actual organizer agreement and data contract before enabling competitions that require team entries or scored judging.

## Verification boundary

The automated suite validates the provider adapter using fake HTTP responses and validates persistence, access control, retries, callbacks, reviewer scope, status transitions, and callback idempotency against a disposable local Supabase database. It does not prove acceptance by a live organizer: no production organizer endpoint, credentials, callback secret, or partner schema were supplied.
