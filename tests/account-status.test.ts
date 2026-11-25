import assert from "node:assert/strict";
import test from "node:test";
import { hasActiveAccount } from "../supabase/functions/_shared/account-status.ts";

function fakeClient(result: { data: unknown; error: unknown }) {
  return {
    from(table: string) {
      assert.equal(table, "profiles");
      return {
        select(columns: string) {
          assert.equal(columns, "account_status");
          return {
            eq(column: string, value: string) {
              assert.equal(column, "id");
              return { maybeSingle: async () => ({ ...result, id: value }) };
            },
          };
        },
      };
    },
  } as never;
}

test("an active account passes the Edge Function guard", async () => {
  assert.equal(await hasActiveAccount(fakeClient({ data: { account_status: "ACTIVE" }, error: null }), "u1"), true);
});

test("a suspended account is rejected by the Edge Function guard", async () => {
  assert.equal(await hasActiveAccount(fakeClient({ data: { account_status: "SUSPENDED" }, error: null }), "u1"), false);
});

test("a hidden or missing profile is rejected", async () => {
  assert.equal(await hasActiveAccount(fakeClient({ data: null, error: null }), "u1"), false);
});

test("a read error fails closed", async () => {
  assert.equal(await hasActiveAccount(fakeClient({ data: null, error: { message: "denied" } }), "u1"), false);
});
