// GET /api/oauth/slack/callback — live-mode Slack OAuth return leg. Mirrors
// the Google callback: exchange, store server-side, mark connected.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { exchangeSlackCode, isLiveOAuth } from "@/lib/oauth/providers";
import { putOAuthTokens } from "@/lib/oauth/oauthStore";
import { backfillSlack } from "@/lib/oauth/slackBackfill";
import type { Connection } from "@/lib/connections/types";

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  // Behind the tunnel, url.origin mis-resolves to https://localhost (forwarded
  // proto + localhost host). Pin to PUBLIC_URL so the token-exchange redirect_uri
  // matches the authorize step and the browser is sent to a real https origin.
  const publicOrigin = process.env.PUBLIC_URL ?? url.origin;
  if (!isLiveOAuth("slack")) return Response.redirect(new URL("/connect/done?failed=1", publicOrigin));

  const code = url.searchParams.get("code");
  const linkId = url.searchParams.get("state");
  if (!code || !linkId) return Response.redirect(new URL("/connect/done?failed=1", publicOrigin));

  const store = getStore();
  const link = store.resolvePendingLink(linkId);
  if (!link || link.platform !== "slack") {
    return Response.redirect(new URL("/connect/done?failed=1", publicOrigin));
  }

  try {
    const tokens = await exchangeSlackCode(code, publicOrigin) as {
      authed_user?: { access_token?: string; id?: string };
      team?: { id?: string };
    };
    await putOAuthTokens(link.deviceId, "slack", tokens as Record<string, unknown>);
    const connection: Connection = {
      id: `slack-${link.deviceId.slice(-8)}`,
      deviceId: link.deviceId,
      platform: "slack",
      status: "backfilling",
      displayName: "Slack",
      backfillProgress: 0,
      createdAt: new Date().toISOString(),
    };
    store.addConnection(connection);
    publish(link.deviceId, {
      type: "connection.status", platform: "slack",
      status: "backfilling", connectionId: connection.id,
    });
    // Import the user's DMs into the oplog (fire-and-forget).
    const userToken = tokens.authed_user?.access_token;
    const userId = tokens.authed_user?.id;
    const teamId = tokens.team?.id;
    if (userToken && userId) {
      void backfillSlack(link.deviceId, connection.id, userToken, userId, teamId);
    }
    return Response.redirect(new URL("/connect/done", publicOrigin));
  } catch {
    return Response.redirect(new URL("/connect/done?failed=1", publicOrigin));
  }
}
