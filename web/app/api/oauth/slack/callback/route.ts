// GET /api/oauth/slack/callback — live-mode Slack OAuth return leg. Mirrors
// the Google callback: exchange, store server-side, mark connected.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { exchangeSlackCode, isLiveOAuth } from "@/lib/oauth/providers";
import type { Connection } from "@/lib/connections/types";

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  if (!isLiveOAuth("slack")) return Response.redirect(new URL("/connect/done?failed=1", url.origin));

  const code = url.searchParams.get("code");
  const linkId = url.searchParams.get("state");
  if (!code || !linkId) return Response.redirect(new URL("/connect/done?failed=1", url.origin));

  const store = getStore();
  const link = store.resolvePendingLink(linkId);
  if (!link || link.platform !== "slack") {
    return Response.redirect(new URL("/connect/done?failed=1", url.origin));
  }

  try {
    const tokens = await exchangeSlackCode(code, url.origin);
    store.setOAuthTokens(link.deviceId, "slack", tokens);
    const connection: Connection = {
      id: `slack-${link.deviceId.slice(-8)}`,
      deviceId: link.deviceId,
      platform: "slack",
      status: "connected",
      displayName: "Slack",
      backfillProgress: 1,
      createdAt: new Date().toISOString(),
    };
    store.addConnection(connection);
    publish(link.deviceId, {
      type: "connection.status", platform: "slack",
      status: "connected", connectionId: connection.id,
    });
    return Response.redirect(new URL("/connect/done", url.origin));
  } catch {
    return Response.redirect(new URL("/connect/done?failed=1", url.origin));
  }
}
