// W3 P4 — the /api/suggest "purpose" lane. Background relationship-brain calls
// (decision/mine) must (a) be gated by their own server flag, default OFF, and
// (b) NEVER consume a user's free-tier manual-draft quota. These are the two
// contract pins the design critique flagged as must-fix before wiring the brain.

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
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}
async function registered(): Promise<string> {
  return (await (await register()).json()).deviceToken as string;
}
const anthropicOk = () => new Response(
  JSON.stringify({ content: [{ type: "text", text: "ACTION: nothing\nCONFIDENCE: 0.2" }] }),
  { status: 200, headers: { "content-type": "application/json" } });

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSpendForTests(); });
afterEach(() => {
  delete process.env.OSMO_REQUIRE_AUTH;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.OSMO_FLAGS;
  vi.unstubAllGlobals();
});

describe("suggest — relationshipBrain flag gates the decision purpose", () => {
  it("purpose=decision with the flag OFF (default) → 503 brain_disabled", async () => {
    const token = await registered();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi", purpose: "decision" }, token));
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("brain_disabled");
  });

  it("purpose=decision with the flag ON proceeds (keyless → 200 mock)", async () => {
    process.env.OSMO_FLAGS = '{"relationshipBrain":true}';
    const token = await registered();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi", purpose: "decision" }, token));
    expect(res.status).toBe(200);
    expect((await res.json()).mock).toBe(true);
  });

  it("a normal draft is unaffected by the relationshipBrain flag being off", async () => {
    const token = await registered();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token)); // purpose defaults to draft
    expect(res.status).toBe(200);
  });
});

describe("suggest — background purposes do NOT consume the draft quota", () => {
  it("a decision call never decrements x-osmo-drafts-remaining", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_FLAGS = '{"relationshipBrain":true}';
    vi.stubGlobal("fetch", vi.fn(anthropicOk));
    const token = await registered();
    // Two background decision calls…
    await suggest(npost({ systemCore: "x", userTurn: "Them: a", purpose: "decision" }, token));
    await suggest(npost({ systemCore: "x", userTurn: "Them: b", purpose: "decision" }, token));
    // …then a real draft: the counter should be at FULL - 1, proving the two
    // decision calls spent nothing from the draft quota.
    const draft = await suggest(npost({ systemCore: "x", userTurn: "Them: c" }, token));
    expect(draft.headers.get("x-osmo-drafts-remaining")).toBe(String(FREE_DRAFTS_PER_WEEK - 1));
  });

  it("a decision call uses the larger max_tokens budget (1200, not 700)", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_FLAGS = '{"relationshipBrain":true}';
    let sentBody: any = null;
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init: RequestInit) => {
      sentBody = JSON.parse(init.body as string);
      return anthropicOk();
    }));
    const token = await registered();
    await suggest(npost({ systemCore: "x", userTurn: "Them: hi", purpose: "decision" }, token));
    expect(sentBody.max_tokens).toBe(1200);
  });
});

describe("suggest — no ungated background bypass (review regression pins)", () => {
  it('an unknown/speculative purpose ("mine") is METERED like a draft, not a free lane', async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(anthropicOk));
    const token = await registered();
    // "mine" is NOT a background lane — it must decrement the draft quota, so a
    // registered device can't skip the weekly cap by tagging calls "mine".
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi", purpose: "mine" }, token));
    expect(res.headers.get("x-osmo-drafts-remaining")).toBe(String(FREE_DRAFTS_PER_WEEK - 1));
  });

  it("a prototype-key purpose (\"toString\") falls back to 700 and stays metered, no 500", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    let sentBody: any = null;
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init: RequestInit) => {
      sentBody = JSON.parse(init.body as string);
      return anthropicOk();
    }));
    const token = await registered();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi", purpose: "toString" }, token));
    expect(res.status).toBe(200);
    expect(sentBody.max_tokens).toBe(700);   // safe fallback, not an inherited function
    expect(res.headers.get("x-osmo-drafts-remaining")).toBe(String(FREE_DRAFTS_PER_WEEK - 1));
  });
});
