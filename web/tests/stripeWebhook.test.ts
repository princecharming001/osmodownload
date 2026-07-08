// Stripe webhook: signature verification + durable subscription writes.

import crypto from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests, getAccounts } from "@/lib/accounts/store";
import { POST as register } from "@/app/api/device/register/route";
import { POST as stripeWebhook } from "@/app/api/webhooks/stripe/route";

const URL = "http://localhost:3000/api/webhooks/stripe";

function sig(raw: string, secret: string): string {
  const t = Math.floor(Date.now() / 1000);
  const v1 = crypto.createHmac("sha256", secret).update(`${t}.${raw}`).digest("hex");
  return `t=${t},v1=${v1}`;
}
function webhook(raw: string, signature?: string): Request {
  return new Request(URL, {
    method: "POST",
    headers: { "content-type": "application/json", ...(signature ? { "stripe-signature": signature } : {}) },
    body: raw,
  });
}
async function deviceId(): Promise<string> {
  return (await (await register()).json()).deviceId as string;
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); });
afterEach(() => { delete process.env.STRIPE_WEBHOOK_SECRET; });

describe("stripe webhook", () => {
  it("no secret configured → 200 no-op (endpoint check passes)", async () => {
    const res = await stripeWebhook(webhook("{}"));
    expect(res.status).toBe(200);
  });

  it("rejects a request with a bad/absent signature when a secret is set", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    expect((await stripeWebhook(webhook("{}"))).status).toBe(400);
    expect((await stripeWebhook(webhook("{}", "t=1,v1=deadbeef"))).status).toBe(400);
  });

  it("a signed checkout.session.completed activates the DURABLE subscription", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    const id = await deviceId();
    const payload = JSON.stringify({
      id: "evt_1", type: "checkout.session.completed",
      data: { object: { client_reference_id: `device:${id}`, plan: "com.osmo.pro.monthly" } },
    });
    const res = await stripeWebhook(webhook(payload, sig(payload, "whsec_test")));
    expect(res.status).toBe(200);
    const sub = await getAccounts().subscriptionForDevice(id);
    expect(sub.subscriptionActive).toBe(true);
    expect(sub.plan).toBe("com.osmo.pro.monthly");
  });

  it("a signed subscription.deleted lapses it (cancellation actually takes effect)", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    const id = await deviceId();
    await getAccounts().setSubscriptionForDevice(id, { subscriptionActive: true });
    const payload = JSON.stringify({
      id: "evt_2", type: "customer.subscription.deleted",
      data: { object: { client_reference_id: `device:${id}` } },
    });
    await stripeWebhook(webhook(payload, sig(payload, "whsec_test")));
    expect((await getAccounts().subscriptionForDevice(id)).subscriptionActive).toBe(false);
  });

  it("is idempotent on redelivered event ids", async () => {
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_test";
    const payload = JSON.stringify({ id: "evt_dup", type: "checkout.session.completed", data: { object: {} } });
    expect((await stripeWebhook(webhook(payload, sig(payload, "whsec_test")))).status).toBe(200);
    const second = await (await stripeWebhook(webhook(payload, sig(payload, "whsec_test")))).json();
    expect(second.dedup).toBe(true);
  });
});
