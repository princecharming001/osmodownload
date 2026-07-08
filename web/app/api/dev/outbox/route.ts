// GET /api/dev/outbox — what /api/sync/send recorded (E2E assertion surface).
// MOCK MODE ONLY.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { isLiveUnipile } from "@/lib/unipile/client";
import { isProduction } from "@/lib/config/runtime";

export async function GET(req: Request): Promise<Response> {
  // Dev E2E surface — unreachable in production.
  if (isLiveUnipile() || isProduction()) return Response.json({ error: "not found" }, { status: 404 });
  try {
    const device = requireDevice(req);
    return Response.json({ outbox: getStore().outbox(device.id) });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
