// A durable device-store OUTAGE must read as "store down" (5xx), never as
// "unknown token" (401): the Mac app answers 401 by re-registering as a fresh
// device, which orphans its Pro subscription and connections. These tests pin
// the whole chain — SupabaseAccountsStore throws on a read error, resolveDevice
// lets it propagate, and the route catch-alls rethrow instead of minting a 401.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import {
  resetAccountsForTests, setAccountsForTests, SupabaseAccountsStore,
} from "@/lib/accounts/store";
import { resolveDevice } from "@/lib/connections/auth";
import { GET as accounts } from "@/app/api/accounts/route";
import { POST as suggest } from "@/app/api/suggest/route";
import { NextRequest } from "next/server";

const BASE = "http://localhost:3000";

/** A supabase-js fake whose every read fails (network blip / Postgres down). */
function failingSupabase() {
  const q = {
    select: () => q, eq: () => q, order: () => q,
    maybeSingle: async () => ({ data: null, error: { message: "fetch failed" } }),
    single: async () => ({ data: null, error: { message: "fetch failed" } }),
  };
  return { from: () => q };
}

beforeEach(() => {
  resetStoreForTests();
  resetAccountsForTests();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  setAccountsForTests(new SupabaseAccountsStore(failingSupabase() as any));
});

describe("durable device-store outage ≠ unknown token", () => {
  it("resolveDevice propagates the store error instead of returning null", async () => {
    await expect(resolveDevice("valid-but-uncached-token")).rejects.toThrow("device store unavailable");
  });

  it("a requireDevice route rethrows (→ 5xx), never converts to a 401", async () => {
    // The token is not in the in-memory map, so auth falls through to the
    // durable read — which is down. AuthError would have produced a 401 here.
    await expect(accounts(new Request(`${BASE}/api/accounts`, {
      headers: { authorization: "Bearer valid-but-uncached-token" },
    }))).rejects.toThrow("device store unavailable");
  });

  it("the suggest route (device-identity chokepoint) also surfaces a 5xx, not 401", async () => {
    await expect(suggest(new NextRequest(`${BASE}/api/suggest`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer valid-but-uncached-token" },
      body: JSON.stringify({ systemCore: "core", userTurn: "hi" }),
    }))).rejects.toThrow("device store unavailable");
  });

  it("a genuinely unknown token (healthy store) still 401s", async () => {
    resetAccountsForTests();   // back to the healthy in-memory store
    const res = await accounts(new Request(`${BASE}/api/accounts`, {
      headers: { authorization: "Bearer nope" },
    }));
    expect(res.status).toBe(401);
  });
});
