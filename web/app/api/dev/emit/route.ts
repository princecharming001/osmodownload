// POST /api/dev/emit {platform, text?} — deterministic E2E trigger: append one
// scripted (or custom) inbound message NOW and ring the doorbell. MOCK MODE
// ONLY — 404s when Unipile is live-configured.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { emitNow } from "@/lib/unipile/mock";
import { isLiveUnipile } from "@/lib/unipile/client";
import type { Platform } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  if (isLiveUnipile()) return Response.json({ error: "not found" }, { status: 404 });
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({}));
    const platform = body.platform as Platform | undefined;
    if (!platform) return Response.json({ error: "platform required" }, { status: 400 });
    const seq = emitNow(device.id, platform, body.text as string | undefined);
    return Response.json({ ok: true, seq });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
