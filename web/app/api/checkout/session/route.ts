// POST /api/checkout/session { plan } — mints the checkout URL the app opens.
// Live mode creates a Stripe Checkout Session (client_reference_id = deviceId
// so the webhook maps the payment back to this device). Keyless mode returns a
// mock-complete URL so the purchase flow is exercisable end-to-end before
// Stripe keys exist.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { createCheckoutSession, priceForPlan } from "@/lib/license/stripe";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await req.json().catch(() => ({})) as { plan?: string };
    const plan = typeof body.plan === "string" ? body.plan : "com.osmo.pro.monthly";
    const origin = process.env.PUBLIC_URL ?? new URL(req.url).origin;

    if (process.env.STRIPE_SECRET_KEY) {
      // Real Stripe Checkout, keyed to the DEVICE (client_reference_id=device:<id>).
      const priceId = priceForPlan(plan);
      if (!priceId) return Response.json({ error: "price not configured" }, { status: 501 });
      const session = await createCheckoutSession({
        clientReferenceId: `device:${device.id}`, priceId,
        successUrl: `${origin}/checkout/done`, cancelUrl: `${origin}/checkout/cancelled`,
      });
      if (!session) return Response.json({ error: "checkout_failed" }, { status: 502 });
      return Response.json({ url: session.url, mode: "stripe" });
    }

    // Keyless dev: mock-complete URL so the flow is exercisable without Stripe.
    const url = new URL("/api/checkout/mock-complete", origin);
    url.searchParams.set("device", device.id);
    url.searchParams.set("plan", plan);
    return Response.json({ url: url.toString(), mode: "mock" });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
