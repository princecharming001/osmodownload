// GET /api/oauth/x/callback — X (Twitter) OAuth 2.0 return leg. Exchanges the
// code (with the PKCE verifier stashed on the pending link), stores tokens
// server-side, marks the connection backfilling, and imports recent DMs.
//
// NB: the callback is registered as http://127.0.0.1:3000/... so it doesn't
// depend on the ephemeral tunnel — the browser redirects to the local backend.

import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { exchangeXCode, isLiveOAuth } from "@/lib/oauth/providers";
import { putOAuthTokens } from "@/lib/oauth/oauthStore";
import { backfillX } from "@/lib/oauth/xBackfill";
import type { Connection } from "@/lib/connections/types";

export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  // The callback runs on the LOCAL backend the browser was redirected to, so its
  // own origin is the right place to send the "connect done" page.
  const origin = url.origin;
  if (!isLiveOAuth("x")) return Response.redirect(new URL("/connect/done?failed=1", origin));

  const code = url.searchParams.get("code");
  const linkId = url.searchParams.get("state");
  if (!code || !linkId) return Response.redirect(new URL("/connect/done?failed=1", origin));

  const store = getStore();
  const link = store.resolvePendingLink(linkId);
  if (!link || link.platform !== "x" || !link.codeVerifier) {
    return Response.redirect(new URL("/connect/done?failed=1", origin));
  }

  try {
    const tokens = await exchangeXCode(code, link.codeVerifier) as { access_token?: string };
    await putOAuthTokens(link.deviceId, "x", tokens as Record<string, unknown>);
    const connection: Connection = {
      id: `x-${link.deviceId.slice(-8)}`,
      deviceId: link.deviceId,
      platform: "x",
      status: "backfilling",
      displayName: "X",
      backfillProgress: 0,
      createdAt: new Date().toISOString(),
    };
    store.addConnection(connection);
    publish(link.deviceId, {
      type: "connection.status", platform: "x",
      status: "backfilling", connectionId: connection.id,
    });
    if (tokens.access_token) {
      void backfillX(link.deviceId, connection.id, tokens.access_token);
    }
    return Response.redirect(new URL("/connect/done", origin));
  } catch {
    return Response.redirect(new URL("/connect/done?failed=1", origin));
  }
}
