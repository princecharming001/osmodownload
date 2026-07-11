// POST /api/connect/rebackfill {platform} — re-run the history import for an
// already-connected account. Lets a platform connected BEFORE the deeper 2-month
// backfill window pull its full history without disconnecting/reconnecting.
// Idempotent: ingest dedups on (platform, messageID), so re-paging never dupes.
// Thin wrapper: the actual per-platform dispatch is shared with the automatic
// incremental sync scheduler (lib/sync/scheduler.ts) via resyncConnection().

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { ensureConnectionsLoaded } from "@/lib/connections/connectionsDurable";
import { resyncConnection } from "@/lib/connections/resync";
import type { Platform } from "@/lib/connections/types";
import { readJsonObject } from "@/lib/http";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await readJsonObject(req) as { platform?: Platform };
    const platform = body.platform;
    if (!platform) return Response.json({ error: "platform required" }, { status: 400 });

    await ensureConnectionsLoaded(device.id); // rehydrate durable connections after a redeploy
    const store = getStore();
    const conn = store.connections(device.id).find(c => c.platform === platform);
    if (!conn) return Response.json({ error: `no ${platform} connection` }, { status: 409 });

    const result = await resyncConnection(device.id, conn.id, platform);
    if (!result.ok) return Response.json({ error: result.error }, { status: result.status });
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
