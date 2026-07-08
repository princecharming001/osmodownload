// GET /api/checkout/mock-complete?device=&plan= — DEV/KEYLESS ONLY. Completes a
// mock purchase (activates the subscription for the device) and shows a return
// page. Disabled the moment a real Stripe key is present, so it can never grant
// Pro in production.

import { getAccounts } from "@/lib/accounts/store";
import { isProduction } from "@/lib/config/runtime";

export async function GET(req: Request): Promise<Response> {
  // Hard gate: never reachable in production (nor once real Stripe is present),
  // regardless of provider config — this route grants Pro with no auth.
  if (process.env.STRIPE_SECRET_KEY || isProduction()) {
    return new Response("Not available in live mode.", { status: 404 });
  }
  const url = new URL(req.url);
  const deviceId = url.searchParams.get("device") ?? "";
  const plan = url.searchParams.get("plan") ?? "com.osmo.pro.monthly";
  const accounts = getAccounts();
  if (!deviceId || !(await accounts.deviceById(deviceId))) {
    return new Response("Unknown device.", { status: 400 });
  }
  await accounts.setSubscriptionForDevice(deviceId, { subscriptionActive: true, plan, licenseKey: "MOCK-CHECKOUT" });

  return new Response(
    `<!doctype html><meta charset="utf-8"><title>Osmo Pro</title>
     <body style="font-family:-apple-system,system-ui;max-width:32rem;margin:6rem auto;text-align:center;color:#08152e">
     <h1>You're on Osmo Pro 🎉</h1>
     <p style="color:#95a0aa">This was a demo checkout (no card charged). Return to Osmo — your plan updates on next launch or when you reopen Plan &amp; Billing.</p>
     </body>`,
    { headers: { "content-type": "text/html; charset=utf-8" } },
  );
}
