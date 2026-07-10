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
    // A non-finite since (NaN/"Infinity") is a broken cursor → 400, and a junk
    // limit must fall back to the default: Math.min(NaN, cap) is NaN, which
    // slices an EMPTY page while hasMore stays true — an infinite poll loop.
    if (!Number.isFinite(since) || since < 0) {
      return Response.json({ error: "bad cursor" }, { status: 400 });
    }
    const rawLimit = Number(url.searchParams.get("limit") || "500");
    const limit = Number.isFinite(rawLimit) && rawLimit > 0 ? Math.min(rawLimit, MAX_LIMIT) : 500;
    return Response.json(getStore().pull(device.id, since, limit));
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
