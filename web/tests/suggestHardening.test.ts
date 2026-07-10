// /api/suggest failure-path hardening: every upstream failure mode must refund
// the reserved free-tier draft and return a sane status (never a crash), junk
// bodies must 4xx, and client-supplied prompts are size-capped so a huge body
// can't burn tokens against the server-side key.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { resetSpendForTests } from "@/lib/license/spendBreaker";
import { weekStart, FREE_DRAFTS_PER_WEEK } from "@/lib/license/quota";
import { POST as register } from "@/app/api/device/register/route";
import { POST as suggest } from "@/app/api/suggest/route";

const BASE = "http://localhost:3000";

function npost(body: unknown, token?: string): NextRequest {
  return new NextRequest(`${BASE}/api/suggest`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

async function registeredWithId(): Promise<{ token: string; deviceId: string }> {
  const body = await (await register()).json();
  return { token: body.deviceToken, deviceId: body.deviceId };
}

const usage = (deviceId: string) => getAccounts().usageCount(deviceId, weekStart(Date.now()));

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSpendForTests(); });
afterEach(() => {
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.OSMO_ANTHROPIC_RETRY_MS;
  vi.unstubAllGlobals();
});

describe("suggest — upstream failure modes refund the reserved draft", () => {
  it("a 200 with a malformed (non-JSON) body → 502 upstream_malformed, credit refunded", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(async () => new Response("definitely not json", { status: 200 })));
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe("upstream_malformed");
    expect(await usage(deviceId)).toBe(0);
  });

  it("a 200 whose content is not an array → empty text, credit refunded (no crash)", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ content: "surprise, a string" }), { status: 200 })));
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(200);
    expect((await res.json()).text).toBe("");
    expect(await usage(deviceId)).toBe(0);
  });

  it("an empty completion (content: []) → 200 {text:\"\"}, credit refunded", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ content: [] }), { status: 200 })));
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(200);
    expect((await res.json()).text).toBe("");
    expect(await usage(deviceId)).toBe(0);
  });

  it("a persistent upstream 429 exhausts the bounded retries → 502, credit refunded", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_ANTHROPIC_RETRY_MS = "1";
    const fetchMock = vi.fn(async () => new Response("rate limited", { status: 429 }));
    vi.stubGlobal("fetch", fetchMock);
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(502);
    expect((await res.json()).status).toBe(429);   // the upstream status is surfaced
    expect(fetchMock).toHaveBeenCalledTimes(3);    // bounded retry, not a storm
    expect(await usage(deviceId)).toBe(0);
  });

  it("a request timeout (aborted fetch) → 502 upstream_timeout, credit refunded", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_ANTHROPIC_RETRY_MS = "1";
    vi.stubGlobal("fetch", vi.fn(async () => {
      throw new DOMException("The operation was aborted.", "AbortError");
    }));
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(502);
    expect((await res.json()).error).toBe("upstream_timeout");
    expect(await usage(deviceId)).toBe(0);
  });
});

describe("suggest — quota boundary", () => {
  const anthropicOk = () => new Response(
    JSON.stringify({ content: [{ type: "text", text: "a\nb\nc" }] }),
    { status: 200, headers: { "content-type": "application/json" } });

  it("the LAST free draft of the week succeeds with remaining=0; the next is 429", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    vi.stubGlobal("fetch", vi.fn(anthropicOk));
    const { token, deviceId } = await registeredWithId();
    const ws = weekStart(Date.now());
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK - 1; i++) await getAccounts().bumpUsage(deviceId, ws);

    const last = await suggest(npost({ systemCore: "x", userTurn: "Them: hi" }, token));
    expect(last.status).toBe(200);
    expect(last.headers.get("x-osmo-drafts-remaining")).toBe("0");

    const over = await suggest(npost({ systemCore: "x", userTurn: "Them: hi again" }, token));
    expect(over.status).toBe(429);
    expect((await over.json()).error).toBe("quota_exceeded");
    // The over-limit reservation was rolled back — count sits exactly at the cap.
    expect(await usage(deviceId)).toBe(FREE_DRAFTS_PER_WEEK);
  });
});

describe("suggest — input validation + size caps", () => {
  it("non-object JSON bodies (null / array / string) → 400, never a crash", async () => {
    const { token } = await registeredWithId();
    for (const body of [null, [], "just a string", 42]) {
      const res = await suggest(npost(body, token));
      expect(res.status).toBe(400);
    }
  });

  it("non-string prompt fields → 400 missing prompt", async () => {
    const { token } = await registeredWithId();
    const res = await suggest(npost({ systemCore: 5, userTurn: { nested: true } }, token));
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("missing prompt");
  });

  it("an oversized systemCore → 413 before any reservation or upstream call", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const { token, deviceId } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x".repeat(33_000), userTurn: "Them: hi" }, token));
    expect(res.status).toBe(413);
    expect((await res.json()).error).toBe("prompt_too_large");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await usage(deviceId)).toBe(0);
  });

  it("an oversized userTurn → 413", async () => {
    const { token } = await registeredWithId();
    const res = await suggest(npost({ systemCore: "x", userTurn: "y".repeat(9_000) }, token));
    expect(res.status).toBe(413);
  });
});
