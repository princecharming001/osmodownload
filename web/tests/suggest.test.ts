// /api/suggest contract pins — the exact shapes the Mac app's generator relies
// on. Quota-429, model-allowlist, open-relay-401, breaker and safety cases live
// in licenseRoutes/hardening/observability already; these fill the gaps: the
// keyless mock body shape, the literal "local-dev" bearer (the prod chat bug),
// the remaining-header decrement across calls, and the kill-switch ordering.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetSpendForTests } from "@/lib/license/spendBreaker";
import { FREE_DRAFTS_PER_WEEK } from "@/lib/license/quota";
import { POST as register } from "@/app/api/device/register/route";
import { POST as suggest } from "@/app/api/suggest/route";

const BASE = "http://localhost:3000";

function npost(body: object, token?: string): NextRequest {
  return new NextRequest(`${BASE}/api/suggest`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

async function registered(): Promise<string> {
  const body = await (await register()).json();
  return body.deviceToken as string;
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSpendForTests(); });
afterEach(() => {
  delete process.env.OSMO_REQUIRE_AUTH;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.OSMO_FLAGS;
  vi.unstubAllGlobals();
});

describe("suggest — keyless mock contract", () => {
  it("keyless + registered device token → 200 { text, mock: true }", async () => {
    const token = await registered();
    const res = await suggest(npost({ systemCore: "core", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.mock).toBe(true);
    expect(typeof body.text).toBe("string");
    expect(body.text).toContain("[mock]");   // clearly marked, never mistaken for the model
  });
});

describe("suggest — device-token auth", () => {
  it("the literal \"local-dev\" bearer is rejected once auth is required (the prod chat bug)", async () => {
    process.env.OSMO_REQUIRE_AUTH = "1";
    const res = await suggest(npost({ systemCore: "core", userTurn: "Them: hi" }, "local-dev"));
    expect(res.status).toBe(401);
    expect((await res.json()).error).toBe("unauthorized");
  });
});

describe("suggest — quota header", () => {
  const anthropicOk = () => new Response(
    JSON.stringify({ content: [{ type: "text", text: "a\nb\nc" }] }),
    { status: 200, headers: { "content-type": "application/json" } });

  it("x-osmo-drafts-remaining decrements across consecutive free-tier drafts", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(anthropicOk));
    const token = await registered();
    const first = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    const second = await suggest(npost({ systemCore: "x", userTurn: "Them: hello again" }, token));
    expect(first.headers.get("x-osmo-drafts-remaining")).toBe(String(FREE_DRAFTS_PER_WEEK - 1));
    expect(second.headers.get("x-osmo-drafts-remaining")).toBe(String(FREE_DRAFTS_PER_WEEK - 2));
  });
});

describe("suggest — aiDrafting kill-switch ordering", () => {
  it("503s BEFORE the keyless mock path (a disabled proxy serves nothing at all)", async () => {
    process.env.OSMO_FLAGS = '{"aiDrafting":false}';
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" })); // keyless, no token
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("ai_disabled");
  });
});
