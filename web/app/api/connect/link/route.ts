// POST /api/connect/link {platform} — mint the URL the app opens so the user
// can connect an account. Unipile-backed platforms → hosted-auth wizard (mock
// wizard keyless); gmail/slack → OAuth (mock wizard keyless).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import type { ConnectLinkResponse, Platform } from "@/lib/connections/types";
import { CONNECTABLE } from "@/lib/connections/types";
import { getUnipile } from "@/lib/unipile/client";
import { ensureUnipileWebhooks } from "@/lib/unipile/webhooks";
import { authURL, isLiveOAuth, makePkce } from "@/lib/oauth/providers";
import { readJsonObject } from "@/lib/http";

export async function POST(req: Request): Promise<Response> {
  let deviceId: string;
  try { deviceId = (await requireDevice(req)).id; }
  catch (e) { if (e instanceof AuthError) return unauthorized(); throw e; }

  const body = await readJsonObject(req);
  const platform = body.platform as Platform | undefined;
  if (!platform || !CONNECTABLE.includes(platform)) {
    return Response.json({ error: `platform must be one of ${CONNECTABLE.join(", ")}` }, { status: 400 });
  }

  const link = getStore().createPendingLink(deviceId, platform);
  // Callbacks (Unipile server-to-server notify; OAuth redirect) must hit a
  // publicly-reachable origin, not the localhost the app calls us on. Prefer
  // PUBLIC_URL (the tunnel/deploy) when set; fall back to the request origin.
  const origin = process.env.PUBLIC_URL ?? new URL(req.url).origin;

  let url: string;
  let mode: ConnectLinkResponse["mode"];
  if (platform === "gmail" || platform === "slack") {
    url = authURL(platform, link.linkId, origin);
    mode = isLiveOAuth(platform) ? "oauth" : "mock";
  } else if (platform === "x") {
    if (isLiveOAuth("x")) {
      // X requires PKCE. Stash the verifier on the pending link (mutating the
      // stored object) so the callback can complete the token exchange.
      const { verifier, challenge } = makePkce();
      link.codeVerifier = verifier;
      url = authURL("x", link.linkId, origin, challenge);
      mode = "oauth";
    } else {
      url = authURL("x", link.linkId, origin);   // keyless → mock wizard
      mode = "mock";
    }
  } else {
    // Lazy catch-up: if the server started before PUBLIC_URL was reachable
    // (e.g. the tunnel came up after boot), the first real connect attempt
    // still gets the webhooks registered. Fire-and-forget — never blocks the
    // hosted-auth link the user is waiting on.
    void ensureUnipileWebhooks();
    const unipile = getUnipile();
    try {
      const out = await unipile.createHostedAuthLink({
        linkId: link.linkId, platform, deviceId, origin,
      });
      url = out.url;
    } catch (e) {
      // The provider refusing (e.g. Unipile "no_client_session" when the
      // instance's session/subscription lapses) is an OUTAGE, not a caller
      // error and not an unhandled 500 — return a typed 503 the app can
      // explain honestly.
      console.error(`[connect/link] ${platform} hosted-auth failed:`, e instanceof Error ? e.message : e);
      return Response.json(
        { error: "provider_unavailable",
          detail: `The ${platform} connector's provider is temporarily unavailable.` },
        { status: 503 });
    }
    mode = unipile.mode === "live" ? "unipile" : "mock";
  }
  const res: ConnectLinkResponse = { url, linkId: link.linkId, mode };
  return Response.json(res);
}
