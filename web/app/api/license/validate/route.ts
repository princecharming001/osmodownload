// POST /api/license/validate { licenseKey? } — the app's entitlement source of
// truth. Optionally redeems a license key, then returns a SIGNED entitlement
// the app verifies with its bundled public key. Editing the app's cached copy
// just breaks the signature and drops to Free.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement, validateLicenseKey } from "@/lib/license/entitlement";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as { licenseKey?: string };
    const accounts = getAccounts();

    if (typeof body.licenseKey === "string" && body.licenseKey.trim()) {
      const { valid, plan } = validateLicenseKey(body.licenseKey);
      if (!valid) return Response.json({ error: "invalid license key" }, { status: 402 });
      await accounts.setSubscriptionForDevice(device.id, { licenseKey: body.licenseKey.trim(), subscriptionActive: true, plan });
    }

    const sub = await accounts.subscriptionForDevice(device.id);
    return Response.json(buildSignedEntitlement(device.id, sub, Date.now()));
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
