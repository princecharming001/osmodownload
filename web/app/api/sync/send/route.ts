// POST /api/sync/send {platform, platformThreadID, text} — send through the
// connected provider. BLOCKS until the provider (or mock) returns the real
// platformMessageID, echoes the full WireMessage; the app ingests the echo and
// a later pull re-delivering the same row dedups to a no-op (no temp IDs).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { getUnipile } from "@/lib/unipile/client";
import type { SendRequest, SendResponse, WireMessage } from "@/lib/connections/types";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const body = await req.json().catch(() => ({})) as Partial<SendRequest>;
    const { platform, platformThreadID, text } = body;
    if (!platform || !platformThreadID || !text?.trim()) {
      return Response.json({ error: "platform, platformThreadID, text required" }, { status: 400 });
    }

    const store = getStore();
    const connection = store.connections(device.id)
      .find(c => c.platform === platform && (c.status === "connected" || c.status === "backfilling"));
    if (!connection) {
      return Response.json({ error: `no live ${platform} connection` }, { status: 409 });
    }

    // Provider send (mock mints a deterministic-enough id; live returns the real one).
    const unipile = getUnipile();
    const sent = await unipile.sendMessage(connection.id, platformThreadID, text);

    const message: WireMessage = {
      platform,
      platformMessageID: sent.messageId,
      platformThreadID,
      senderHandle: null,
      isFromMe: true,
      text,
      sentAt: new Date().toISOString(),
      readAt: null,
    };

    // Record in the oplog (so other devices / re-pulls see it) + mock outbox.
    const seq = store.appendRows(device.id, { messages: [message] });
    store.recordOutbound(device.id, message);
    if (seq > 0) publish(device.id, { type: "sync.dirty", seq });

    const res: SendResponse = { message };
    return Response.json(res);
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
