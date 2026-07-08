// POST /api/account/upgrade — web-session-authed "go Pro" for the account
// portal. In mock/keyless mode it activates the subscription immediately so the
// whole flow (and app↔web sync) is exercisable. When STRIPE_SECRET_KEY is set
// this instead returns a Stripe Checkout URL (TODO: real session) — the portal
// redirects there and the webhook flips the subscription on payment.

import { getAccounts } from "@/lib/accounts/store";
import { readSessionToken } from "@/lib/auth/session";
import { sameOrigin, forbidden } from "@/lib/auth/csrf";
import { createCheckoutSession, priceForPlan } from "@/lib/license/stripe";

export async function POST(req: Request): Promise<Response> {
  if (!sameOrigin(req)) return forbidden();
  const token = readSessionToken(req);
  const accounts = getAccounts();
  const user = token ? await accounts.webSessionUser(token) : null;
  if (!user) return Response.json({ error: "not signed in" }, { status: 401 });

  const plan = (await req.json().catch(() => ({})) as { plan?: string }).plan ?? "com.osmo.pro.monthly";

  if (process.env.STRIPE_SECRET_KEY) {
    // Real Stripe Checkout, keyed to the USER (client_reference_id=user:<id>) so
    // the webhook maps a web-initiated subscription back to the account.
    const priceId = priceForPlan(plan);
    if (!priceId) return Response.json({ error: "price not configured" }, { status: 501 });
    const base = process.env.PUBLIC_URL ?? new URL(req.url).origin;
    const session = await createCheckoutSession({
      clientReferenceId: `user:${user.id}`, priceId,
      successUrl: `${base}/account?upgraded=1`, cancelUrl: `${base}/account`,
    });
    if (!session) return Response.json({ error: "checkout_failed" }, { status: 502 });
    return Response.json({ url: session.url, mode: "stripe" });
  }

  // Mock (dev only): activate the user's subscription now (no card charged). Keyed
  // to the USER, so it's shared by every device they've linked + the website.
  await accounts.setSubscriptionForUser(user.id, { subscriptionActive: true, plan: "com.osmo.pro.monthly", licenseKey: "MOCK-WEB" });
  return Response.json({ ok: true, mode: "mock", plan: "Pro" });
}
