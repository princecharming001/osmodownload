// GET /api/sync/pull?since=<cursor>&limit=500 — THE source of truth. Returns
// oplog rows with seq > since, ascending, as a normalized wire batch. The app
// ingests first, persists the cursor second (crash-safe: re-pull is idempotent
// thanks to deterministic IDs + change-aware ingest).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";

const MAX_LIMIT = 1000;

export async function GET(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const url = new URL(req.url);
    const since = Number(url.searchParams.get("since") || "0");
    const limit = Math.min(Number(url.searchParams.get("limit") || "500"), MAX_LIMIT);
    if (Number.isNaN(since) || since < 0) {
      return Response.json({ error: "bad cursor" }, { status: 400 });
    }
    return Response.json(getStore().pull(device.id, since, limit));
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
