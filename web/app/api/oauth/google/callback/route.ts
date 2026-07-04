// GET /api/oauth/google/callback — live-mode Google OAuth return leg. Exchanges
// the code, stores tokens server-side (never sent to the app), marks the
// connection live. Keyless mode never routes here (mock wizard instead).

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { exchangeGoogleCode, isLiveOAuth } from "@/lib/oauth/providers";
import type { Connection } from "@/lib/connections/types";

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  if (!isLiveOAuth("gmail")) return Response.redirect(new URL("/connect/done?failed=1", url.origin));

  const code = url.searchParams.get("code");
  const linkId = url.searchParams.get("state");
  if (!code || !linkId) return Response.redirect(new URL("/connect/done?failed=1", url.origin));

  const store = getStore();
  const link = store.resolvePendingLink(linkId);
  if (!link || link.platform !== "gmail") {
    return Response.redirect(new URL("/connect/done?failed=1", url.origin));
  }

  try {
    const tokens = await exchangeGoogleCode(code, url.origin);
    store.setOAuthTokens(link.deviceId, "gmail", tokens);
    const connection: Connection = {
      id: `gmail-${link.deviceId.slice(-8)}`,
      deviceId: link.deviceId,
      platform: "gmail",
      status: "connected",
      displayName: "Gmail",
      backfillProgress: 1,
      createdAt: new Date().toISOString(),
    };
    store.addConnection(connection);
    publish(link.deviceId, {
      type: "connection.status", platform: "gmail",
      status: "connected", connectionId: connection.id,
    });
    return Response.redirect(new URL("/connect/done", url.origin));
  } catch {
    return Response.redirect(new URL("/connect/done?failed=1", url.origin));
  }
}
