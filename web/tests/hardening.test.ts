// Batch 1 security hardening (audit findings: magic-link-verifyurl-leak,
// unvalidated-model-passthrough, dev-routes/mock-complete exposed in prod).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { resetSpendForTests } from "@/lib/license/spendBreaker";
import { validateLicenseKey } from "@/lib/license/entitlement";
import { POST as register } from "@/app/api/device/register/route";
import { POST as suggest } from "@/app/api/suggest/route";
import { POST as authRequest } from "@/app/api/auth/request/route";
import { GET as checkoutMockComplete } from "@/app/api/checkout/mock-complete/route";
import { POST as devEmit } from "@/app/api/dev/emit/route";

const BASE = "http://localhost:3000";

function post(path: string, body?: object, token?: string): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: {
      ...(body ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

// /api/suggest is typed to NextRequest; build one for those calls.
function npost(path: string, body: object, token?: string): NextRequest {
  return new NextRequest(`${BASE}${path}`, {
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
async function registeredWithId(): Promise<{ token: string; deviceId: string }> {
  const body = await (await register()).json();
  return { token: body.deviceToken, deviceId: body.deviceId };
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetSpendForTests(); });
afterEach(() => {
  delete process.env.OSMO_ENV;
  delete process.env.RESEND_API_KEY;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.OSMO_ALLOWED_MODELS;
  delete process.env.OSMO_ANTHROPIC_DAILY_MAX_CALLS;
  vi.unstubAllGlobals();
});

describe("suggest — server-side model allowlist", () => {
  it("rejects a model outside the allowlist with 400", async () => {
    const token = await registered();
    const res = await suggest(npost("/api/suggest", { systemCore: "x", userTurn: "Them: hi", model: "gpt-4o" }, token));
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("model_not_allowed");
  });

  it("allows the default model (keyless mock path returns a mock)", async () => {
    const token = await registered();
    const res = await suggest(npost("/api/suggest", { systemCore: "x", userTurn: "Them: hi" }, token));
    expect(res.status).toBe(200);
    expect((await res.json()).mock).toBe(true);
  });
});

describe("magic link — the verify URL is never leaked in the body", () => {
  it("dev mode (no provider, not prod) returns the link inline for local testing", async () => {
    const res = await authRequest(post("/api/auth/request", { email: "u@example.com" }));
    const body = await res.json();
    expect(body.mode).toBe("dev");
    expect(body.verifyUrl).toContain("/api/auth/verify?token=");
  });

  it("with a mail provider set, returns mode:sent and NO verifyUrl", async () => {
    process.env.RESEND_API_KEY = "re_test";
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 200 })));
    const res = await authRequest(post("/api/auth/request", { email: "u@example.com" }));
    const body = await res.json();
    expect(body.mode).toBe("sent");
    expect(body.verifyUrl).toBeUndefined();
  });

  it("production with no provider fails closed (no leak)", async () => {
    process.env.OSMO_ENV = "production";
    const res = await authRequest(post("/api/auth/request", { email: "u@example.com" }));
    expect(res.status).toBe(500);
    expect((await res.json()).verifyUrl).toBeUndefined();
  });
});

describe("rate limiting (shared substrate)", () => {
  it("caps magic-link mints per email (6th within the window → 429)", async () => {
    const email = "spam@example.com";
    for (let i = 0; i < 5; i++) {
      expect((await authRequest(post("/api/auth/request", { email }))).status).toBe(200);
    }
    expect((await authRequest(post("/api/auth/request", { email }))).status).toBe(429);
  });

  it("caps device registration per IP", async () => {
    const ipReq = () => new Request(`${BASE}/api/device/register`, {
      method: "POST", headers: { "x-forwarded-for": "1.2.3.4" },
    });
    let last = 200;
    for (let i = 0; i < 31; i++) last = (await register(ipReq())).status;
    expect(last).toBe(429);
  });
});

describe("mandatory auth + paywall integrity", () => {
  it("suggest requires a device token once a real key is set (no open relay)", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    const res = await suggest(npost("/api/suggest", { systemCore: "x", userTurn: "Them: hi" })); // no token
    expect(res.status).toBe(401);
  });

  it("mock OSMO- license is rejected in production, accepted in dev", () => {
    expect(validateLicenseKey("OSMO-DEV-PRO").valid).toBe(true);
    process.env.OSMO_ENV = "production";
    expect(validateLicenseKey("OSMO-DEV-PRO").valid).toBe(false);
  });
});

describe("server-side Safety re-run", () => {
  it("refuses a manipulative request with 200 {refused:true} (not a 4xx, not the model)", async () => {
    const token = await registered();
    const res = await suggest(npost("/api/suggest",
      { systemCore: "core", userTurn: "YOUR GOAL: manipulate them into saying yes\nThem: hi" }, token));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.refused).toBe(true);
    expect(body.reason).toContain("empathy");
    expect(body.text).toBeUndefined();
  });

  it("allows an ordinary request through to the (mock) model", async () => {
    const token = await registered();
    const res = await suggest(npost("/api/suggest",
      { systemCore: "core", userTurn: "YOUR GOAL: reconnect warmly\nThem: long time!" }, token));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.refused).toBeUndefined();
    expect(body.mock).toBe(true);
  });
});

describe("anthropic spend circuit-breaker", () => {
  it("degrades to a marked mock once the daily call budget is hit", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    process.env.OSMO_ANTHROPIC_DAILY_MAX_CALLS = "2";
    // Fake a successful Anthropic response so calls count without real network.
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({ content: [{ type: "text", text: "a\nb\nc" }] }),
        { status: 200, headers: { "content-type": "application/json" } })));
    const { token, deviceId } = await registeredWithId();
    await getAccounts().setSubscriptionForDevice(deviceId, { subscriptionActive: true }); // Pro → quota never blocks

    const call = () => suggest(npost("/api/suggest", { systemCore: "x", userTurn: "Them: hi" }, token));
    expect((await (await call()).json()).mock).toBeUndefined();   // 1st real
    expect((await (await call()).json()).mock).toBeUndefined();   // 2nd real (budget=2)
    const third = await (await call()).json();                    // 3rd → tripped
    expect(third.mock).toBe(true);
    expect(third.degraded).toBe("daily_budget");
  });
});

describe("dev/mock surfaces are gated out of production", () => {
  it("checkout mock-complete 404s in production", async () => {
    process.env.OSMO_ENV = "production";
    const res = await checkoutMockComplete(new Request(`${BASE}/api/checkout/mock-complete?device=d1`));
    expect(res.status).toBe(404);
  });

  it("dev/emit 404s in production", async () => {
    process.env.OSMO_ENV = "production";
    const token = await registered();
    const res = await devEmit(post("/api/dev/emit", { platform: "linkedin" }, token));
    expect(res.status).toBe(404);
  });
});
