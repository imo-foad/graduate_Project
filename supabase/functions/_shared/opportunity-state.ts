// Mirror of SQL public.is_opportunity_open(status, deadline, end_at). Boundary: deadline/end_at == now is still open.
export interface OpenCheckable { status?: string | null; deadline?: string | null; end_at?: string | null }

// Product scope, final decision 2026-11-26 (docs/PRODUCT_DECISIONS.md): only JOB, INTERNSHIP and
// TRAINING are active opportunity types. EVENT, CONFERENCE and VOLUNTEER are not independent types;
// SCHOLARSHIP (issue #14) and COMPETITION (issue #15) are permanently cancelled. Legacy rows are kept
// for audit only. This list mirrors SQL public.is_opportunity_type_active exactly.
export const ACTIVE_OPPORTUNITY_TYPES: readonly string[] = ["JOB", "INTERNSHIP", "TRAINING"];
export const CANCELLED_OPPORTUNITY_TYPES: readonly string[] = ["SCHOLARSHIP", "COMPETITION"];
export const OUT_OF_SCOPE_OPPORTUNITY_TYPES: readonly string[] = ["EVENT", "CONFERENCE", "VOLUNTEER"];
export const INACTIVE_OPPORTUNITY_TYPES: readonly string[] = [
  ...OUT_OF_SCOPE_OPPORTUNITY_TYPES, ...CANCELLED_OPPORTUNITY_TYPES,
];

/**
 * Exact mirror of SQL `coalesce(p_type in ('JOB','INTERNSHIP','TRAINING'), false)`: an allow-list,
 * case-sensitive, without trimming. `"job"`, `"JOB "`, `" JOB"`, `""`, whitespace, unknown values,
 * excluded product types and non-strings are all false. A deny-list here would silently accept unknown
 * types that SQL rejects — keep this in sync with public.is_opportunity_type_active.
 */
export function isActiveOpportunityType(type: string | null | undefined): boolean {
  return typeof type === "string" && ACTIVE_OPPORTUNITY_TYPES.includes(type);
}
export function isCancelledOpportunityType(type: string | null | undefined): boolean {
  return typeof type === "string" && CANCELLED_OPPORTUNITY_TYPES.includes(type);
}
export function isOutOfScopeOpportunityType(type: string | null | undefined): boolean {
  return typeof type === "string" && OUT_OF_SCOPE_OPPORTUNITY_TYPES.includes(type);
}

export function isOpportunityOpen(o: OpenCheckable | null | undefined, now: Date = new Date()): boolean {
  if (!o || o.status !== "ACTIVE") return false;
  const t = now.getTime();
  if (o.deadline && Date.parse(o.deadline) < t) return false;
  if (o.end_at && Date.parse(o.end_at) < t) return false;
  return true;
}

/** Defence in depth: drop recommendations whose opportunity is no longer open (cached or fresh). */
export function filterOpenRecommendations<T extends { opportunity?: OpenCheckable | null }>(items: T[], now: Date = new Date()): T[] {
  return items.filter((r) => isOpportunityOpen(r.opportunity, now));
}

// Registration availability mirrors public.register_for_training (SQL keeps the legacy RPC name
// register_for_event for client compatibility):
//   upcoming  -> registration_opens_at is still in the future
//   open      -> capacity is null (unlimited) or registered_count < capacity
//   waitlist  -> capacity reached and waitlist_enabled
//   full      -> capacity reached without a waitlist (the RPC raises TRAINING_FULL, so never recommend)
//   closed    -> the opportunity itself is no longer open
export interface AvailabilityCheckable extends OpenCheckable {
  /** Registration availability is a TRAINING-only workflow; JOB/INTERNSHIP use applications. */
  type?: string | null;
  registration_opens_at?: string | null;
  capacity?: number | null;
  registered_count?: number | null;
  waitlist_enabled?: boolean | null;
  company_id?: string | null;
  company_verification_status?: string | null;
}
export type AvailabilityStatus = "OPEN" | "UPCOMING" | "WAITLIST_ONLY" | "FULL" | "CLOSED";

/**
 * null means availability is not modelled for the opportunity. Direct registration is a TRAINING-only
 * workflow (public.register_for_event rejects every other type), so JOB and INTERNSHIP are governed by
 * their application workflow: capacity/registered_count/registration_opens_at/waitlist_enabled must
 * never turn them into FULL, UPCOMING or WAITLIST_ONLY. Unknown and missing types are treated the same
 * way instead of inheriting TRAINING rules.
 */
export function registrationAvailability(o: AvailabilityCheckable | null | undefined, now: Date = new Date()): AvailabilityStatus | null {
  if (!o) return null;
  if (o.type !== "TRAINING") return null;
  if (!isOpportunityOpen(o, now)) return "CLOSED";
  const hasRegistrationData = (o.capacity !== null && o.capacity !== undefined)
    || (o.registration_opens_at !== null && o.registration_opens_at !== undefined);
  if (!hasRegistrationData) return null;
  if (o.registration_opens_at && Date.parse(o.registration_opens_at) > now.getTime()) return "UPCOMING";
  const capacity = o.capacity ?? null;
  const taken = o.registered_count ?? 0;
  if (capacity !== null && taken >= capacity) return o.waitlist_enabled === true ? "WAITLIST_ONLY" : "FULL";
  return "OPEN";
}

/**
 * Drop recommendations that cannot be acted on: anything outside the active type allow-list, closed
 * opportunities and full training programmes without a waitlist. Defence in depth for the project
 * scope: the SQL candidate projection already applies the same allow-list, and this also filters
 * legacy cached rows.
 */
export function filterAvailableRecommendations<T extends { opportunity?: (AvailabilityCheckable & { type?: string | null }) | null }>(
  items: T[],
  now: Date = new Date(),
): T[] {
  return items.filter((r) => {
    // Universal closure rule for every type: a cached row whose opportunity was deleted, closed,
    // cancelled or expired must not leak through the cache.
    const o = r.opportunity;
    if (!o || !isOpportunityOpen(o, now)) return false;
    // Parity with the SQL candidate projection: only the active allow-list may be surfaced. This also
    // catches legacy cached rows for cancelled/excluded lines, unknown types and malformed type values.
    if (!isActiveOpportunityType(o.type)) return false;
    // The opportunity exposes a safe, denormalized company status because the companies table itself
    // is intentionally member/admin-only under RLS. Missing or suspended companies are not actionable.
    if (o.company_id && o.company_verification_status !== "VERIFIED") return false;
    // Registration availability only constrains TRAINING; JOB/INTERNSHIP and unknown types return null.
    const status = registrationAvailability(o, now);
    return status !== "CLOSED" && status !== "FULL";
  });
}
