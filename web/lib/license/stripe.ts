// Minimal Stripe REST calls (no SDK) — Checkout Session creation for the app and
// web "go Pro" flows. Activated only when STRIPE_SECRET_KEY is set; the plan→price
// map comes from env (a HUMAN GATE to fill the real price ids).

export function priceForPlan(plan: string): string | null {
  if (plan === "com.osmo.pro.annual") return process.env.OSMO_STRIPE_PRICE_ANNUAL ?? null;
  return process.env.OSMO_STRIPE_PRICE_MONTHLY ?? null; // default: monthly
}

export async function createCheckoutSession(opts: {
  clientReferenceId: string;   // "device:<id>" or "user:<id>" (see webhook D13c)
  priceId: string;
  successUrl: string;
  cancelUrl: string;
}): Promise<{ url: string } | null> {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) return null;
  const form = new URLSearchParams();
  form.set("mode", "subscription");
  form.set("client_reference_id", opts.clientReferenceId);
  form.set("line_items[0][price]", opts.priceId);
  form.set("line_items[0][quantity]", "1");
  form.set("success_url", opts.successUrl);
  form.set("cancel_url", opts.cancelUrl);
  try {
    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { url?: string };
    return data.url ? { url: data.url } : null;
  } catch {
    return null;
  }
}
