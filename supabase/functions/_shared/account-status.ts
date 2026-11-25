// Shared guard for user-facing Edge Functions.
// Two layers of defence:
//   1. Auth-level: a suspended account is banned in GoTrue, so getUser() fails with
//      403 user_banned even while an old JWT is still cryptographically valid.
//   2. Data-level: the restrictive RLS policy `active_account_guard` hides the profile
//      from a suspended account. The explicit read below turns that silence into a
//      stable 403 ACCOUNT_UNAVAILABLE instead of an empty (but successful) payload.
// Service-role workers and HMAC callbacks do not use this helper.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type AuthFailure = { status?: number; code?: string; message?: string } | null | undefined;

export function isBannedAuthError(error: AuthFailure): boolean {
  if (!error) return false;
  return error.code === "user_banned" || /banned/i.test(error.message ?? "");
}

export async function hasActiveAccount(client: SupabaseClient, userId: string): Promise<boolean> {
  const { data, error } = await client
    .from("profiles")
    .select("account_status")
    .eq("id", userId)
    .maybeSingle();
  if (error) return false;
  return (data as { account_status?: string | null } | null)?.account_status === "ACTIVE";
}
