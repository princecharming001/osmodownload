// POST /api/account/link { appleUserID, email?, fullName? } — the Mac app calls
// this after Sign in with Apple (device Bearer auth). It finds-or-creates the
// user for that Apple identity, links THIS device to them, and merges any
// anonymous device subscription into the account. After this, the same account
// + subscription is shared with the website (log in there with the same email).
// Returns the fresh signed entitlement so the app's tier reflects the account.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement } from "@/lib/license/entitlement";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as { appleUserID?: string; email?: string; fullName?: string };
    const appleUserID = (body.appleUserID ?? "").toString().trim();
    if (!appleUserID) return Response.json({ error: "appleUserID required" }, { status: 400 });

    const accounts = getAccounts();
    const user = await accounts.findOrCreateUserByApple(
      appleUserID,
      body.email?.trim() || null,
      body.fullName?.trim() || null,
    );
    if (!user) {
      // First-ever sign-in with no email from Apple — can't create an account.
      return Response.json({ error: "email required to create your account" }, { status: 422 });
    }

    await accounts.linkDeviceToUser(device.id, user.id);
    const sub = await accounts.subscriptionForDevice(device.id);
    return Response.json({
      user: { id: user.id, email: user.email, displayName: user.displayName },
      entitlement: buildSignedEntitlement(device.id, sub, Date.now()),
    });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
