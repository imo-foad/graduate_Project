// Shared guard for user-facing Edge Functions.
// The restrictive RLS policy `active_account_guard` already hides rows from suspended accounts;
// this explicit check turns that silence into a stable 403 ACCOUNT_UNAVAILABLE response instead
// of returning an empty (but successful) payload. Service-role workers and HMAC callbacks do not
// use this helper.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export async function hasActiveAccount(client: SupabaseClient, userId: string): Promise<boolean> {
  const { data, error } = await client
    .from("profiles")
    .select("account_status")
    .eq("id", userId)
    .maybeSingle();
  if (error) return false;
  return (data as { account_status?: string | null } | null)?.account_status === "ACTIVE";
}
