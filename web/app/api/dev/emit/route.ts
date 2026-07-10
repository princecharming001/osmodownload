// POST /api/dev/emit {platform, text?, senderHandle?, senderName?, threadKey?}
// — deterministic E2E trigger: append one scripted (or custom) inbound message
// NOW and ring the doorbell. The optional sender fields drive the message from
// a distinct thread/person (e.g. an automated email address for classifier
// probes) instead of the scripted default. MOCK MODE ONLY — 404s when Unipile
// is live-configured.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { emitNow } from "@/lib/unipile/mock";
import { isLiveUnipile } from "@/lib/unipile/client";
import { isProduction } from "@/lib/config/runtime";
import type { Platform } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  // Dev E2E surface — unreachable in production (would let any device inject inbound messages).
  if (isLiveUnipile() || isProduction()) return Response.json({ error: "not found" }, { status: 404 });
  try {
    const device = await requireDevice(req);
    const body = await req.json().catch(() => ({}));
    const platform = body.platform as Platform | undefined;
    if (!platform) return Response.json({ error: "platform required" }, { status: 400 });
    const senderHandle = body.senderHandle as string | undefined;
    const sender = senderHandle ? {
      handle: senderHandle,
      name: (body.senderName as string | undefined) ?? null,
      threadKey: body.threadKey as string | undefined,
    } : undefined;
    const seq = emitNow(device.id, platform, body.text as string | undefined, sender);
    return Response.json({ ok: true, seq });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
