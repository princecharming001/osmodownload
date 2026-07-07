// POST /api/account/upgrade — web-session-authed "go Pro" for the account
// portal. In mock/keyless mode it activates the subscription immediately so the
// whole flow (and app↔web sync) is exercisable. When STRIPE_SECRET_KEY is set
// this instead returns a Stripe Checkout URL (TODO: real session) — the portal
// redirects there and the webhook flips the subscription on payment.

import { getAccounts } from "@/lib/accounts/store";
import { readSessionToken } from "@/lib/auth/session";

export async function POST(req: Request): Promise<Response> {
  const token = readSessionToken(req);
  const accounts = getAccounts();
  const user = token ? await accounts.webSessionUser(token) : null;
  if (!user) return Response.json({ error: "not signed in" }, { status: 401 });

  if (process.env.STRIPE_SECRET_KEY) {
    // TODO(live): create a Stripe Checkout Session (client_reference_id=user.id,
    // mode:subscription) and return { url }. Until then, don't grant Pro.
    return Response.json({ error: "checkout not configured" }, { status: 501 });
  }

  // Mock: activate the user's subscription now (no card charged). Keyed to the
  // USER, so it's shared by every device they've linked + the website.
  await accounts.setSubscriptionForUser(user.id, { subscriptionActive: true, plan: "com.osmo.pro.monthly", licenseKey: "MOCK-WEB" });
  return Response.json({ ok: true, mode: "mock", plan: "Pro" });
}
