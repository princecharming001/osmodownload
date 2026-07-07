// POST /api/checkout/session { plan } — mints the checkout URL the app opens.
// Live mode creates a Stripe Checkout Session (client_reference_id = deviceId
// so the webhook maps the payment back to this device). Keyless mode returns a
// mock-complete URL so the purchase flow is exercisable end-to-end before
// Stripe keys exist.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as { plan?: string };
    const plan = typeof body.plan === "string" ? body.plan : "com.osmo.pro.monthly";
    const origin = process.env.PUBLIC_URL ?? new URL(req.url).origin;

    if (process.env.STRIPE_SECRET_KEY) {
      // TODO(live): create a real Stripe Checkout Session here —
      //   stripe.checkout.sessions.create({
      //     mode: "subscription",
      //     line_items: [{ price: PRICE_ID_FOR[plan], quantity: 1 }],
      //     client_reference_id: device.id,
      //     success_url: `${origin}/checkout/done`,
      //     cancel_url: `${origin}/checkout/cancelled`,
      //   })
      // and return { url: session.url }. Until then, fall through to mock so
      // nothing charges a card by accident.
    }

    const url = new URL("/api/checkout/mock-complete", origin);
    url.searchParams.set("device", device.id);
    url.searchParams.set("plan", plan);
    return Response.json({ url: url.toString(), mode: process.env.STRIPE_SECRET_KEY ? "stripe-pending" : "mock" });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
