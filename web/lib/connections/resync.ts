// Resync a single connection — the shared core behind both the user-facing
// "re-import history" button (/api/connect/rebackfill) and the automatic
// incremental sync scheduler (lib/sync/scheduler.ts). One code path, two
// triggers: extracted here so the scheduler reuses the exact same,
// already-proven per-platform dispatch instead of duplicating it.

import { getStore } from "./memoryStore";
import { publish } from "./events";
import { backfillConnection } from "./backfill";
import { backfillGmail } from "../oauth/gmailBackfill";
import { backfillSlack } from "../oauth/slackBackfill";
import { backfillX } from "../oauth/xBackfill";
import { freshOAuthToken } from "../oauth/tokens";
import { isLiveOAuth } from "../oauth/providers";
import type { Platform } from "./types";

export type ResyncResult = { ok: true } | { ok: false; error: string; status: number };

/** Re-run the platform-appropriate importer for one already-connected
    account. Flips the connection to "backfilling" (the importers' own
    stop-check requires that exact state — a bare SSE ping isn't enough,
    they bail on the first loop iteration otherwise) and fires the run
    fire-and-forget; the app's cursor-pull drains the deeper history as it
    lands. Idempotent: ingest dedups on (platform, messageID).

    Re-entrant-safe: a connection already "backfilling" is a no-op success
    rather than a second concurrent run — without this, the scheduler and a
    manual "re-import" (or two scheduler ticks straddling a slow backfill)
    could both fire the same connection at once, doubling upstream API load
    and resetting the in-flight progress bar back to 0. */
export async function resyncConnection(
  deviceId: string, connectionId: string, platform: Platform,
): Promise<ResyncResult> {
  try {
    const store = getStore();
    const conn = store.connections(deviceId).find(c => c.id === connectionId);
    if (!conn) return { ok: false, error: `no ${platform} connection`, status: 409 };
    if (conn.status === "backfilling") return { ok: true };

    // Resolve tokens BEFORE flipping status so a missing token never strands
    // the connection in "backfilling". Keyless mock connections have no OAuth
    // tokens; they fall through to the Unipile no-op, which flips the status
    // straight back to connected.
    const unipileFallback = () => backfillConnection({ deviceId, accountId: conn.id, platform });
    let run = unipileFallback;
    if (platform === "gmail" || platform === "x") {
      const accessToken = (await freshOAuthToken(deviceId, platform)).access_token;
      if (accessToken) {
        run = platform === "gmail"
          ? () => backfillGmail(deviceId, conn.id, accessToken)
          : () => backfillX(deviceId, conn.id, accessToken);
      } else if (isLiveOAuth(platform)) {
        return { ok: false, error: `reconnect ${platform} first`, status: 409 };
      }
    } else if (platform === "slack") {
      const tokens = await freshOAuthToken(deviceId, "slack") as {
        authed_user?: { access_token?: string; id?: string };
        team?: { id?: string };
      };
      const userToken = tokens.authed_user?.access_token;
      const userId = tokens.authed_user?.id;
      if (userToken && userId) {
        run = () => backfillSlack(deviceId, conn.id, userToken, userId, tokens.team?.id);
      } else if (isLiveOAuth("slack")) {
        return { ok: false, error: "reconnect slack first", status: 409 };
      }
    }

    // A token refresh failure just above may have already flipped this
    // connection to "degraded" (freshOAuthToken → markConnectionDegraded) —
    // re-check rather than clobbering that back to "backfilling" with a
    // token bundle we now know is stale/invalid.
    if (store.connections(deviceId).find(c => c.id === connectionId)?.status === "degraded") {
      return { ok: false, error: `reconnect ${platform} first`, status: 409 };
    }

    store.setConnectionStatus(conn.id, "backfilling", 0);
    publish(deviceId, {
      type: "connection.status", platform, status: "backfilling", connectionId: conn.id,
    });
    void run();
    return { ok: true };
  } catch (err) {
    // Callers include fire-and-forget sites (`void resyncConnection(...)`);
    // never let an unexpected throw escape as an unhandled rejection.
    return { ok: false, error: (err as Error).message, status: 500 };
  }
}
