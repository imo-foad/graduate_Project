// Mirror of SQL public.is_opportunity_open(status, deadline, end_at). Boundary: deadline/end_at == now is still open.
export interface OpenCheckable { status?: string | null; deadline?: string | null; end_at?: string | null }

// Product scope (mirror of SQL public.is_opportunity_type_active). Scholarship (issue #14) and
// Competition (issue #15) are cancelled product lines: their rows are retained for history only.
export const CANCELLED_OPPORTUNITY_TYPES: readonly string[] = ["SCHOLARSHIP", "COMPETITION"];
export function isCancelledOpportunityType(type: string | null | undefined): boolean {
  return typeof type === "string" && CANCELLED_OPPORTUNITY_TYPES.includes(type);
}
export function isActiveOpportunityType(type: string | null | undefined): boolean {
  return typeof type === "string" && type.length > 0 && !isCancelledOpportunityType(type);
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

// Registration availability mirrors public.register_for_event / public.apply_for_competition:
//   upcoming  -> registration_opens_at is still in the future
//   open      -> capacity is null (unlimited) or registered_count < capacity
//   waitlist  -> capacity reached and waitlist_enabled
//   full      -> capacity reached without a waitlist (the RPC raises EVENT_FULL, so never recommend)
//   closed    -> the opportunity itself is no longer open
export interface AvailabilityCheckable extends OpenCheckable {
  registration_opens_at?: string | null;
  capacity?: number | null;
  registered_count?: number | null;
  waitlist_enabled?: boolean | null;
}
export type AvailabilityStatus = "OPEN" | "UPCOMING" | "WAITLIST_ONLY" | "FULL" | "CLOSED";

/** null means the opportunity carries no registration data, so availability is not modelled for it. */
export function registrationAvailability(o: AvailabilityCheckable | null | undefined, now: Date = new Date()): AvailabilityStatus | null {
  if (!o) return null;
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
 * Drop recommendations that cannot be acted on: cancelled opportunity types, closed opportunities and
 * full events without a waitlist. Defence in depth for the project scope: the SQL candidate projection
 * already excludes cancelled types, and this also filters legacy cached rows.
 */
export function filterAvailableRecommendations<T extends { opportunity?: (AvailabilityCheckable & { type?: string | null }) | null }>(
  items: T[],
  now: Date = new Date(),
): T[] {
  return items.filter((r) => {
    if (r.opportunity && isCancelledOpportunityType(r.opportunity.type)) return false;
    const status = registrationAvailability(r.opportunity, now);
    return status !== "CLOSED" && status !== "FULL";
  });
}
