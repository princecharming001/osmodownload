// GET /api/oauth/google/callback — live-mode Google OAuth return leg. Exchanges
// the code, stores tokens server-side (never sent to the app), marks the
// connection live. Keyless mode never routes here (mock wizard instead).

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { exchangeGoogleCode, isLiveOAuth } from "@/lib/oauth/providers";
import { backfillGmail } from "@/lib/oauth/gmailBackfill";
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
    const tokens = await exchangeGoogleCode(code, url.origin) as { access_token?: string };
    store.setOAuthTokens(link.deviceId, "gmail", tokens);
    const connection: Connection = {
      id: `gmail-${link.deviceId.slice(-8)}`,
      deviceId: link.deviceId,
      platform: "gmail",
      status: "backfilling",
      displayName: "Gmail",
      backfillProgress: 0,
      createdAt: new Date().toISOString(),
    };
    store.addConnection(connection);
    publish(link.deviceId, {
      type: "connection.status", platform: "gmail",
      status: "backfilling", connectionId: connection.id,
    });
    // Import recent mail into the oplog (fire-and-forget; the app pulls it in).
    if (tokens.access_token) {
      void backfillGmail(link.deviceId, connection.id, tokens.access_token);
    }
    return Response.redirect(new URL("/connect/done", url.origin));
  } catch {
    return Response.redirect(new URL("/connect/done?failed=1", url.origin));
  }
}
