// POST /api/webhooks/stripe — Stripe subscription lifecycle → durable license.
//
// Fixes the two audit findings on this route: (1) it now VERIFIES the signature
// (no more trust-the-JSON), and (2) it writes to the DURABLE accounts store
// (osmo_subscriptions), the same source /api/license/validate reads — not the
// ephemeral in-memory map, so a cancellation actually lapses and survives restart.
//
// client_reference_id convention (D13c): "device:<id>" (app checkout) or
// "user:<id>" (web checkout); a bare id is treated as a device for back-compat.
// Until STRIPE_WEBHOOK_SECRET is set this 200s as a no-op so Stripe's endpoint
// check passes.

import { getAccounts } from "@/lib/accounts/store";
import { verifyStripeSignature } from "@/lib/license/stripeSig";

// Event-id idempotency (Stripe redelivers). Per-process for now; moves to a
// durable processed-events table under 0-B.
const seen = new Set<string>();

export async function POST(req: Request): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  const raw = await req.text();
  if (!secret) return Response.json({ ok: true, note: "stripe not configured" });

  if (!verifyStripeSignature(raw, req.headers.get("stripe-signature"), secret)) {
    return Response.json({ error: "bad signature" }, { status: 400 });
  }

  let event: { id?: string; type?: string; data?: { object?: Record<string, unknown> } };
  try { event = JSON.parse(raw); } catch { return Response.json({ error: "bad payload" }, { status: 400 }); }

  if (event.id) {
    if (seen.has(event.id)) return Response.json({ ok: true, dedup: true });
    seen.add(event.id);
  }

  const obj = event.data?.object ?? {};
  const ref = (obj.client_reference_id ?? obj.clientReferenceId) as string | undefined;
  const accounts = getAccounts();

  const setActive = async (active: boolean, plan?: string): Promise<void> => {
    if (!ref) return;
    const patch = active
      ? { subscriptionActive: true, plan: plan ?? "com.osmo.pro.monthly", licenseKey: "STRIPE" }
      : { subscriptionActive: false };
    if (ref.startsWith("user:")) await accounts.setSubscriptionForUser(ref.slice(5), patch);
    else await accounts.setSubscriptionForDevice(ref.startsWith("device:") ? ref.slice(7) : ref, patch);
  };

  switch (event.type) {
    case "checkout.session.completed":
      await setActive(true, obj.plan as string | undefined);
      break;
    case "customer.subscription.created":
    case "customer.subscription.updated": {
      const status = obj.status as string | undefined;
      const active = status ? ["active", "trialing"].includes(status) : true;
      await setActive(active, obj.plan as string | undefined);
      break;
    }
    case "customer.subscription.deleted":
    case "charge.refunded":
    case "charge.dispute.created":
      await setActive(false);
      break;
  }
  return Response.json({ ok: true });
}
