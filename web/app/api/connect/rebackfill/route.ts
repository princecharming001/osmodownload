// POST /api/connect/rebackfill {platform} — re-run the history import for an
// already-connected account. Lets a platform connected BEFORE the deeper 2-month
// backfill window pull its full history without disconnecting/reconnecting.
// Idempotent: ingest dedups on (platform, messageID), so re-paging never dupes.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { ensureConnectionsLoaded } from "@/lib/connections/connectionsDurable";
import { publish } from "@/lib/connections/events";
import { backfillConnection } from "@/lib/connections/backfill";
import { backfillGmail } from "@/lib/oauth/gmailBackfill";
import { backfillSlack } from "@/lib/oauth/slackBackfill";
import { backfillX } from "@/lib/oauth/xBackfill";
import { freshOAuthToken } from "@/lib/oauth/tokens";
import { isLiveOAuth } from "@/lib/oauth/providers";
import type { Platform } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await req.json().catch(() => ({})) as { platform?: Platform };
    const platform = body.platform;
    if (!platform) return Response.json({ error: "platform required" }, { status: 400 });

    await ensureConnectionsLoaded(device.id); // rehydrate durable connections after a redeploy
    const store = getStore();
    const conn = store.connections(device.id).find(c => c.platform === platform);
    if (!conn) return Response.json({ error: `no ${platform} connection` }, { status: 409 });

    // Per-platform dispatch — gmail/slack/x are OAuth-backed importers, the
    // rest go through Unipile. (Sending every platform into the Unipile
    // importer was the old bug: an OAuth platform's re-import silently no-oped.)
    // Resolve tokens BEFORE flipping status so a missing token never strands
    // the connection in "backfilling". Keyless mock connections have no OAuth
    // tokens; they fall through to the Unipile no-op, which flips the status
    // straight back to connected.
    const unipileFallback = () => backfillConnection({ deviceId: device.id, accountId: conn.id, platform });
    let run = unipileFallback;
    if (platform === "gmail" || platform === "x") {
      const accessToken = (await freshOAuthToken(device.id, platform)).access_token;
      if (accessToken) {
        run = platform === "gmail"
          ? () => backfillGmail(device.id, conn.id, accessToken)
          : () => backfillX(device.id, conn.id, accessToken);
      } else if (isLiveOAuth(platform)) {
        return Response.json({ error: `reconnect ${platform} first` }, { status: 409 });
      }
    } else if (platform === "slack") {
      const tokens = await freshOAuthToken(device.id, "slack") as {
        authed_user?: { access_token?: string; id?: string };
        team?: { id?: string };
      };
      const userToken = tokens.authed_user?.access_token;
      const userId = tokens.authed_user?.id;
      if (userToken && userId) {
        run = () => backfillSlack(device.id, conn.id, userToken, userId, tokens.team?.id);
      } else if (isLiveOAuth("slack")) {
        return Response.json({ error: "reconnect slack first" }, { status: 409 });
      }
    }

    // The importers' stop-check requires the status to actually BE "backfilling"
    // (a bare SSE ping isn't enough — they'd bail on the first loop iteration).
    store.setConnectionStatus(conn.id, "backfilling", 0);
    publish(device.id, {
      type: "connection.status", platform, status: "backfilling", connectionId: conn.id,
    });
    // Fire-and-forget; the app's cursor-pull drains the deeper history as it lands.
    void run();
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
