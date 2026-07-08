// POST /api/trial/start — starts the 14-day trial, server-recorded per device
// so deleting a local file can't reset it. Returns the signed entitlement.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement } from "@/lib/license/entitlement";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const sub = await getAccounts().startTrialForDevice(device.id, Date.now());   // idempotent
    return Response.json(buildSignedEntitlement(device.id, sub, Date.now()));
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
