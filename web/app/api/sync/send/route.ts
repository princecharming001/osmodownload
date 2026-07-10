// POST /api/sync/send {platform, platformThreadID, text} — send through the
// connected provider. BLOCKS until the provider (or mock) returns the real
// platformMessageID, echoes the full WireMessage; the app ingests the echo and
// a later pull re-delivering the same row dedups to a no-op (no temp IDs).

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { ensureConnectionsLoaded } from "@/lib/connections/connectionsDurable";
import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { getUnipile } from "@/lib/unipile/client";
import { sendGmail, sendSlack, sendX } from "@/lib/oauth/send";
import { isLiveOAuth } from "@/lib/oauth/providers";
import { freshOAuthToken } from "@/lib/oauth/tokens";
import { recallSend, sendOnce } from "@/lib/connections/sendIdempotency";
import type { SendRequest, SendResponse, WireMessage } from "@/lib/connections/types";
import { readJsonObject } from "@/lib/http";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    const body = await readJsonObject(req) as Partial<SendRequest>;
    const { platform, platformThreadID, text, idempotencyKey } = body;
    if (!platform || !platformThreadID || !text?.trim()) {
      return Response.json({ error: "platform, platformThreadID, text required" }, { status: 400 });
    }

    // Idempotent retry: if we already completed this exact send, return the same
    // message rather than delivering a duplicate to the recipient.
    if (idempotencyKey) {
      const prior = recallSend(device.id, idempotencyKey);
      if (prior) return Response.json({ message: prior } satisfies SendResponse);
    }

    await ensureConnectionsLoaded(device.id); // rehydrate durable connections after a redeploy
    const store = getStore();
    const connection = store.connections(device.id)
      .find(c => c.platform === platform && (c.status === "connected" || c.status === "backfilling"));
    if (!connection) {
      return Response.json({ error: `no live ${platform} connection` }, { status: 409 });
    }

    // Route to the right provider. Gmail/Slack use their own APIs with the stored
    // OAuth token (Unipile only covers LinkedIn/WhatsApp/Instagram). In keyless
    // mock mode every platform falls through to the mock sender.
    const doSend = async (): Promise<WireMessage> => {
      let sent: { messageId: string };
      if (platform === "gmail" && isLiveOAuth("gmail")) {
        sent = await sendGmail(await freshOAuthToken(device.id, "gmail"), platformThreadID, text);
      } else if (platform === "slack" && isLiveOAuth("slack")) {
        sent = await sendSlack(await freshOAuthToken(device.id, "slack"), platformThreadID, text);
      } else if (platform === "x" && isLiveOAuth("x")) {
        sent = await sendX(await freshOAuthToken(device.id, "x"), platformThreadID, text);
      } else {
        sent = await getUnipile().sendMessage(connection.id, platformThreadID, text);
      }
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
      return message;
    };

    let message: WireMessage;
    try {
      // sendOnce covers the CONCURRENT double-POST too (both requests in
      // flight before either completed): the second call awaits the first's
      // in-flight promise instead of delivering a duplicate to the recipient.
      message = idempotencyKey
        ? await sendOnce(device.id, idempotencyKey, doSend)
        : await doSend();
    } catch (err) {
      // Provider rejected (bad thread, outside session window, revoked token) —
      // a real error the client should surface, NOT queue-and-retry forever.
      return Response.json({ error: `send rejected: ${(err as Error).message}` }, { status: 422 });
    }

    const res: SendResponse = { message };
    return Response.json(res);
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
