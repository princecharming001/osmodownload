// POST /api/account/link { appleUserID, email?, fullName? } — the Mac app calls
// this after Sign in with Apple (device Bearer auth). It finds-or-creates the
// user for that Apple identity, links THIS device to them, and merges any
// anonymous device subscription into the account. After this, the same account
// + subscription is shared with the website (log in there with the same email).
// Returns the fresh signed entitlement so the app's tier reflects the account.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getAccounts } from "@/lib/accounts/store";
import { buildSignedEntitlement } from "@/lib/license/entitlement";
import { verifyAppleIdentityToken } from "@/lib/auth/appleVerify";
import { isProduction } from "@/lib/config/runtime";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as {
      appleUserID?: string; email?: string; fullName?: string; identityToken?: string; nonce?: string;
    };

    // Derive the Apple identity from a VERIFIED token — never a client-supplied
    // appleUserID (that was the account-takeover hole). The bare-field path is
    // dev-only; production requires a real Apple-signed identity token.
    let appleUserID = "";
    let email: string | null = null;
    const clientId = process.env.OSMO_APPLE_CLIENT_ID;
    if (body.identityToken && clientId) {
      const id = await verifyAppleIdentityToken(body.identityToken, { clientId, nonce: body.nonce });
      if (!id) return Response.json({ error: "invalid apple token" }, { status: 401 });
      appleUserID = id.sub;
      email = id.email;                                    // trust only the token
    } else if (!isProduction()) {
      appleUserID = (body.appleUserID ?? "").toString().trim();
      email = body.email?.trim() || null;
    } else {
      return Response.json({ error: "identity token required" }, { status: 401 });
    }
    if (!appleUserID) return Response.json({ error: "appleUserID required" }, { status: 400 });

    const accounts = getAccounts();
    const user = await accounts.findOrCreateUserByApple(
      appleUserID,
      email,
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
