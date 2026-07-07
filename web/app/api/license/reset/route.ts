// POST /api/license/reset — DEV/KEYLESS ONLY. Clears the device's subscription
// + trial so the Free/paywall states can be re-tested. Disabled once a real
// Stripe key is present (real subscriptions are managed via the portal).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement } from "@/lib/license/entitlement";

export async function POST(req: Request): Promise<Response> {
  if (process.env.STRIPE_SECRET_KEY) {
    return Response.json({ error: "not available in live mode" }, { status: 404 });
  }
  try {
    const device = requireDevice(req);
    const accounts = getAccounts();
    const sub = await accounts.setSubscriptionForDevice(device.id, { subscriptionActive: false, plan: null, licenseKey: null, trialStartedAt: null });
    return Response.json(buildSignedEntitlement(device.id, sub, Date.now()));
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
