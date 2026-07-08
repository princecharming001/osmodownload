// POST /api/promo/redeem { code } — referral / promo codes. Trial codes extend
// (or start) the trial; discount codes are acknowledged here and applied as a
// Stripe coupon at checkout later. Returns the fresh signed entitlement.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement, TRIAL_DAYS } from "@/lib/license/entitlement";

const DAY_MS = 86_400_000;

type Promo = { kind: "trial"; days: number } | { kind: "discount"; note: string };

// Demo catalog — swap for a real promo table / referral service later.
const CODES: Record<string, Promo> = {
  FRIEND: { kind: "trial", days: 14 },      // referral: +2 weeks
  LAUNCH: { kind: "trial", days: 30 },      // launch promo: +1 month
  WELCOME: { kind: "discount", note: "20% off your first month at checkout" },
};

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await req.json().catch(() => ({})) as { code?: string };
    const code = (body.code ?? "").toString().trim().toUpperCase();
    const promo = CODES[code];
    if (!promo) return Response.json({ error: "unknown code" }, { status: 404 });

    const accounts = getAccounts();
    const now = Date.now();
    if (promo.kind === "trial") {
      const rec = await accounts.subscriptionForDevice(device.id);
      const existingEnd = rec.trialStartedAt ? rec.trialStartedAt + TRIAL_DAYS * DAY_MS : now;
      const newEnd = Math.max(existingEnd, now) + promo.days * DAY_MS;
      // Back-compute the start so resolveTier (start + TRIAL_DAYS) yields newEnd.
      await accounts.setSubscriptionForDevice(device.id, { trialStartedAt: newEnd - TRIAL_DAYS * DAY_MS });
    }
    const sub = await accounts.subscriptionForDevice(device.id);
    const signed = buildSignedEntitlement(device.id, sub, now);
    return Response.json({ ...signed, applied: promo.kind });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
