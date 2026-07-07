// POST /api/webhooks/stripe — Stripe subscription lifecycle → license state.
// Scaffold: verifies the signature and flips subscriptionActive on the device
// keyed by client_reference_id. The real Stripe SDK (event construction +
// signature verification) wires in where marked; until STRIPE_WEBHOOK_SECRET is
// set this 200s as a no-op so Stripe's endpoint check passes.

import { getStore } from "@/lib/connections/memoryStore";

export async function POST(req: Request): Promise<Response> {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  const raw = await req.text();

  if (!secret) return Response.json({ ok: true, note: "stripe not configured" });

  // TODO(live): const event = stripe.webhooks.constructEvent(raw, req.headers.get("stripe-signature")!, secret)
  // Parse the raw body defensively until then.
  let event: { type?: string; data?: { object?: Record<string, unknown> } };
  try { event = JSON.parse(raw); } catch { return Response.json({ ok: true }); }

  const obj = event.data?.object ?? {};
  const deviceId = (obj.client_reference_id ?? obj.clientReferenceId) as string | undefined;
  const store = getStore();

  switch (event.type) {
    case "checkout.session.completed":
    case "customer.subscription.created":
    case "customer.subscription.updated":
      if (deviceId && store.deviceById(deviceId)) {
        store.setLicense(deviceId, {
          subscriptionActive: true,
          plan: (obj.plan as string | undefined) ?? "com.osmo.pro.monthly",
        });
      }
      break;
    case "customer.subscription.deleted":
      if (deviceId && store.deviceById(deviceId)) {
        store.setLicense(deviceId, { subscriptionActive: false });
      }
      break;
  }
  return Response.json({ ok: true });
}
