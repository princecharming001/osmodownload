// POST /api/connect/link {platform} — mint the URL the app opens so the user
// can connect an account. Unipile-backed platforms → hosted-auth wizard (mock
// wizard keyless); gmail/slack → OAuth (mock wizard keyless).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import type { ConnectLinkResponse, Platform } from "@/lib/connections/types";
import { CONNECTABLE } from "@/lib/connections/types";
import { getUnipile } from "@/lib/unipile/client";
import { authURL, isLiveOAuth } from "@/lib/oauth/providers";

export async function POST(req: Request): Promise<Response> {
  let deviceId: string;
  try { deviceId = requireDevice(req).id; }
  catch (e) { if (e instanceof AuthError) return unauthorized(); throw e; }

  const body = await req.json().catch(() => ({}));
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
  } else {
    const unipile = getUnipile();
    const out = await unipile.createHostedAuthLink({
      linkId: link.linkId, platform, deviceId, origin,
    });
    url = out.url;
    mode = unipile.mode === "live" ? "unipile" : "mock";
  }
  const res: ConnectLinkResponse = { url, linkId: link.linkId, mode };
  return Response.json(res);
}
