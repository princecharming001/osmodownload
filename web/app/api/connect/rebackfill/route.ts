// POST /api/connect/rebackfill {platform} — re-run the history import for an
// already-connected account. Lets a platform connected BEFORE the deeper 2-month
// backfill window pull its full history without disconnecting/reconnecting.
// Idempotent: ingest dedups on (platform, messageID), so re-paging never dupes.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { backfillConnection } from "@/lib/connections/backfill";
import type { Platform } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await req.json().catch(() => ({})) as { platform?: Platform };
    const platform = body.platform;
    if (!platform) return Response.json({ error: "platform required" }, { status: 400 });

    const conn = getStore().connections(device.id).find(c => c.platform === platform);
    if (!conn) return Response.json({ error: `no ${platform} connection` }, { status: 409 });

    publish(device.id, {
      type: "connection.status", platform, status: "backfilling", connectionId: conn.id,
    });
    // Fire-and-forget; the app's cursor-pull drains the deeper history as it lands.
    void backfillConnection({ deviceId: device.id, accountId: conn.id, platform });
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
