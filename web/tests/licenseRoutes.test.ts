import { beforeEach, describe, expect, it } from "vitest";
import { NextRequest } from "next/server";
import crypto from "node:crypto";
import { resetStoreForTests, getStore } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { DEV_PUBLIC_X, type EntitlementPayload } from "@/lib/license/sign";
import { weekStart, FREE_DRAFTS_PER_WEEK } from "@/lib/license/quota";
import { POST as register } from "@/app/api/device/register/route";
import { POST as validateLicense } from "@/app/api/license/validate/route";
import { POST as startTrial } from "@/app/api/trial/start/route";
import { POST as checkoutSession } from "@/app/api/checkout/session/route";
import { POST as suggest } from "@/app/api/suggest/route";
import { POST as deleteAccount } from "@/app/api/account/delete/route";
import { POST as linkAccount } from "@/app/api/account/link/route";
import { POST as feedback } from "@/app/api/feedback/route";

const BASE = "http://localhost:3000";

function req(path: string, token?: string, body?: unknown): Request {
  return new Request(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function nreq(path: string, token: string, body: unknown): NextRequest {
  return new NextRequest(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

async function registered(): Promise<{ token: string; deviceId: string }> {
  const b = await (await register()).json();
  return { token: b.deviceToken, deviceId: b.deviceId };
}

function decodePayload(entitlement: string): EntitlementPayload {
  return JSON.parse(Buffer.from(entitlement, "base64url").toString());
}
function verify(entitlement: string, signature: string): boolean {
  const pub = crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: DEV_PUBLIC_X }, format: "jwk" });
  return crypto.verify(null, Buffer.from(entitlement, "base64url"), pub, Buffer.from(signature, "base64url"));
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); delete process.env.ANTHROPIC_API_KEY; delete process.env.STRIPE_SECRET_KEY; });

describe("license + trial routes", () => {
  it("validate returns a verifiable Free entitlement for a new device", async () => {
    const { token, deviceId } = await registered();
    const res = await validateLicense(req("/api/license/validate", token, {}));
    expect(res.status).toBe(200);
    const signed = await res.json();
    expect(verify(signed.entitlement, signed.signature)).toBe(true);
    const p = decodePayload(signed.entitlement);
    expect(p.tier).toBe("free");
    expect(p.deviceId).toBe(deviceId);
  });

  it("redeeming an OSMO- license flips to Pro; a bad key is 402", async () => {
    const { token } = await registered();
    const bad = await validateLicense(req("/api/license/validate", token, { licenseKey: "nope" }));
    expect(bad.status).toBe(402);

    const good = await validateLicense(req("/api/license/validate", token, { licenseKey: "OSMO-TEST-1" }));
    const signed = await good.json();
    expect(decodePayload(signed.entitlement).tier).toBe("pro");
  });

  it("trial start is idempotent and marks the entitlement trial", async () => {
    const { token } = await registered();
    const first = decodePayload(await (await startTrial(req("/api/trial/start", token, {}))).json().then((j) => j.entitlement));
    expect(first.tier).toBe("trial");
    expect(first.trialStartedAt).toBeTypeOf("number");
    // A second call must not re-open or change the start.
    const second = decodePayload(await (await startTrial(req("/api/trial/start", token, {}))).json().then((j) => j.entitlement));
    expect(second.trialStartedAt).toBe(first.trialStartedAt);
  });

  it("requires auth", async () => {
    expect((await validateLicense(req("/api/license/validate", undefined, {}))).status).toBe(401);
    expect((await startTrial(req("/api/trial/start", undefined, {}))).status).toBe(401);
  });

  it("checkout returns a mock-complete URL in keyless mode", async () => {
    const { token } = await registered();
    const res = await checkoutSession(req("/api/checkout/session", token, { plan: "com.osmo.pro.monthly" }));
    const body = await res.json();
    expect(body.mode).toBe("mock");
    expect(body.url).toContain("/api/checkout/mock-complete");
  });
});

describe("account deletion + feedback", () => {
  it("delete purges the device's server record (token no longer resolves)", async () => {
    const { token, deviceId } = await registered();
    await getAccounts().setSubscriptionForDevice(deviceId, { subscriptionActive: true });
    expect(getStore().deviceByToken(token)).not.toBeNull();

    const res = await deleteAccount(req("/api/account/delete", token, {}));
    expect(res.status).toBe(200);
    expect(getStore().deviceByToken(token)).toBeNull();
    expect(await getAccounts().deviceById(deviceId)).toBeNull();
    expect((await getAccounts().subscriptionForDevice(deviceId)).subscriptionActive).toBe(false);
  });

  it("feedback accepts a message and rejects an empty one", async () => {
    const { token } = await registered();
    expect((await feedback(req("/api/feedback", token, { message: "" }))).status).toBe(400);
    expect((await feedback(req("/api/feedback", token, { message: "love it" }))).status).toBe(200);
  });

  it("both require auth", async () => {
    expect((await deleteAccount(req("/api/account/delete", undefined, {}))).status).toBe(401);
    expect((await feedback(req("/api/feedback", undefined, { message: "x" }))).status).toBe(401);
  });
});

describe("suggest quota enforcement", () => {
  it("a free device over its weekly cap gets 429 (with a real key set)", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";   // makes the route enforce quota (real bill to protect)
    const { token, deviceId } = await registered();
    // Exhaust the week without hitting the model.
    const ws = weekStart(Date.now());
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK; i++) getStore().bumpUsage(deviceId, ws);

    const res = await suggest(nreq("/api/suggest", token, { systemCore: "x", userTurn: "Them: hi" }));
    expect(res.status).toBe(429);
    expect((await res.json()).error).toBe("quota_exceeded");
  });

  it("a Pro device is never quota-limited (unlimited)", async () => {
    process.env.ANTHROPIC_API_KEY = "sk-test";
    const { token, deviceId } = await registered();
    await getAccounts().setSubscriptionForDevice(deviceId, { subscriptionActive: true });
    const ws = weekStart(Date.now());
    for (let i = 0; i < FREE_DRAFTS_PER_WEEK + 3; i++) getStore().bumpUsage(deviceId, ws);
    // Over the free cap, but Pro → quota passes. (It then tries the model; with a
    // fake key the upstream fetch fails → 502, which still proves quota didn't 429.)
    const res = await suggest(nreq("/api/suggest", token, { systemCore: "x", userTurn: "Them: hi" }));
    expect(res.status).not.toBe(429);
  });
});

describe("account link — one account across the app + the web", () => {
  it("links a device to a user, and the subscription is shared both ways", async () => {
    const { token } = await registered();

    // Sign in with Apple in the app → link this device to a user account.
    const linkRes = await linkAccount(req("/api/account/link", token, { appleUserID: "apple.1", email: "u@x.com", fullName: "U X" }));
    expect(linkRes.status).toBe(200);
    const { user } = await linkRes.json();
    expect(user.email).toBe("u@x.com");

    // Web-side upgrade, keyed to the USER.
    await getAccounts().setSubscriptionForUser(user.id, { subscriptionActive: true, plan: "com.osmo.pro.monthly" });

    // The app's entitlement (device → user → sub) now reflects Pro …
    const signed = await (await validateLicense(req("/api/license/validate", token, {}))).json();
    expect(decodePayload(signed.entitlement).tier).toBe("pro");
    // … and the website reads the very same subscription.
    expect((await getAccounts().subscriptionForUser(user.id)).subscriptionActive).toBe(true);
  });

  it("a device's pre-account trial merges into the account on link", async () => {
    const { token } = await registered();
    await startTrial(req("/api/trial/start", token, {}));   // anonymous device trial
    const { user } = await (await linkAccount(req("/api/account/link", token, { appleUserID: "apple.2", email: "t@x.com" }))).json();
    // The trial the device started is now the user's.
    expect((await getAccounts().subscriptionForUser(user.id)).trialStartedAt).toBeTypeOf("number");
  });

  it("first Apple sign-in with no email can't create an account (422); and it needs auth", async () => {
    const { token } = await registered();
    expect((await linkAccount(req("/api/account/link", token, { appleUserID: "apple.noemail" }))).status).toBe(422);
    expect((await linkAccount(req("/api/account/link", undefined, { appleUserID: "a" }))).status).toBe(401);
  });
});
