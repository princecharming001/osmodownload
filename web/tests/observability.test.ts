// Observability — /api/health exposes readiness + metrics; the draft path
// increments counters.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetSpendForTests } from "@/lib/license/spendBreaker";
import { POST as register } from "@/app/api/device/register/route";
import { POST as suggest } from "@/app/api/suggest/route";
import { GET as health } from "@/app/api/health/route";

const BASE = "http://localhost:3000";
function npost(body: object, token: string): NextRequest {
  return new NextRequest(`${BASE}/api/suggest`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}
async function token(): Promise<string> {
  return (await (await register()).json()).deviceToken as string;
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSpendForTests(); });
afterEach(() => { delete process.env.ANTHROPIC_API_KEY; delete process.env.OSMO_ANTHROPIC_DAILY_MAX_CALLS; vi.unstubAllGlobals(); });

describe("observability", () => {
  it("health reports ok, readiness, and a metrics snapshot", async () => {
    const body = await (await health()).json();
    expect(body.ok).toBe(true);
    expect(body.ready).toHaveProperty("db");        // n/a when no Supabase in tests
    expect(body.metrics).toBeTypeOf("object");
  });

  it("a successful draft increments draft.ok", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ content: [{ type: "text", text: "a" }] }),
        { status: 200, headers: { "content-type": "application/json" } })));
    await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, await token()));
    expect((await (await health()).json()).metrics["draft.ok"]).toBe(1);
  });

  it("a tripped spend breaker increments draft.spend_breaker_trip", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_ANTHROPIC_DAILY_MAX_CALLS = "1"; // 2nd real call trips
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ content: [{ type: "text", text: "a" }] }),
        { status: 200, headers: { "content-type": "application/json" } })));
    const t = await token();
    await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, t)); // records 1 call
    await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, t)); // trips (1 >= 1)
    expect((await (await health()).json()).metrics["draft.spend_breaker_trip"]).toBe(1);
  });
});
