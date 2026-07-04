// GET /api/events — the per-device SSE doorbell stream. Carries sync.dirty /
// connection.status / backfill.progress hints (never message bodies) plus a
// 25s `: ping` heartbeat the client uses as a liveness check.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { makeSSEStream } from "@/lib/connections/events";

export const dynamic = "force-dynamic";

export async function GET(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    return new Response(makeSSEStream(device.id), {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache, no-transform",
        "connection": "keep-alive",
        "x-accel-buffering": "no",
      },
    });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
