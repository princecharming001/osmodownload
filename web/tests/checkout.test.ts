// Real Stripe Checkout session creation (app + web paths) + upgrade CSRF.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { SESSION_COOKIE } from "@/lib/auth/session";
import { POST as register } from "@/app/api/device/register/route";
import { POST as checkoutSession } from "@/app/api/checkout/session/route";
import { POST as upgrade } from "@/app/api/account/upgrade/route";

const BASE = "http://localhost:3000";

function stubStripe(url = "https://checkout.stripe.com/c/pay/xyz") {
  const fn = vi.fn(async (_input: string | URL | Request, _init?: RequestInit) =>
    new Response(JSON.stringify({ url }), { status: 200, headers: { "content-type": "application/json" } }));
  vi.stubGlobal("fetch", fn);
  return fn;
}
async function token(): Promise<string> {
  return (await (await register()).json()).deviceToken as string;
}
function bearerReq(path: string, tok: string, body: object): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${tok}` },
    body: JSON.stringify(body),
  });
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); });
afterEach(() => {
  delete process.env.STRIPE_SECRET_KEY; delete process.env.OSMO_STRIPE_PRICE_MONTHLY;
  vi.unstubAllGlobals();
});

describe("checkout/session (app path)", () => {
  it("keyless → mock-complete URL", async () => {
    const res = await checkoutSession(bearerReq("/api/checkout/session", await token(), { plan: "com.osmo.pro.monthly" }));
    expect((await res.json()).url).toContain("/api/checkout/mock-complete");
  });

  it("with Stripe configured → creates a session keyed to device:<id>", async () => {
    process.env.STRIPE_SECRET_KEY = "sk_test"; process.env.OSMO_STRIPE_PRICE_MONTHLY = "price_123";
    const fetchMock = stubStripe();
    const res = await checkoutSession(bearerReq("/api/checkout/session", await token(), { plan: "com.osmo.pro.monthly" }));
    const body = await res.json();
    expect(body.mode).toBe("stripe");
    expect(body.url).toContain("checkout.stripe.com");
    const sentBody = String(fetchMock.mock.calls[0][1]?.body);
    expect(sentBody).toContain("client_reference_id=device%3A");
    expect(sentBody).toContain("price_123");
  });
});

describe("account/upgrade (web path)", () => {
  async function signedInCookie(): Promise<string> {
    const user = await getAccounts().findOrCreateUserByEmail("u@x.com");
    const session = await getAccounts().createWebSession(user.id);
    return `${SESSION_COOKIE}=${session.token}`;
  }
  function webReq(cookie: string | null, origin: string | null): Request {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (cookie) headers.cookie = cookie;
    if (origin) headers.origin = origin;
    return new Request(`${BASE}/api/account/upgrade`, { method: "POST", headers, body: "{}" });
  }

  it("rejects a cross-origin request (CSRF)", async () => {
    const res = await upgrade(webReq(await signedInCookie(), "https://evil.example.com"));
    expect(res.status).toBe(403);
  });

  it("keyless + same-origin → activates the user's mock subscription", async () => {
    const res = await upgrade(webReq(await signedInCookie(), BASE));
    expect((await res.json()).mode).toBe("mock");
    const user = await getAccounts().findOrCreateUserByEmail("u@x.com");
    expect((await getAccounts().subscriptionForUser(user.id)).subscriptionActive).toBe(true);
  });

  it("with Stripe → returns a checkout URL keyed to user:<id>", async () => {
    process.env.STRIPE_SECRET_KEY = "sk_test"; process.env.OSMO_STRIPE_PRICE_MONTHLY = "price_123";
    const fetchMock = stubStripe();
    const res = await upgrade(webReq(await signedInCookie(), BASE));
    expect((await res.json()).url).toContain("checkout.stripe.com");
    expect(String(fetchMock.mock.calls[0][1]?.body)).toContain("client_reference_id=user%3A");
  });
});
