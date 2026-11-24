// Mirror of SQL public.is_opportunity_open(status, deadline, end_at). Boundary: deadline/end_at == now is still open.
export interface OpenCheckable { status?: string | null; deadline?: string | null; end_at?: string | null }

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
