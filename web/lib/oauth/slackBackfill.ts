// Live Slack history import. With the user token we list the user's DMs, page
// each one's recent messages, resolve sender names, normalize to wire rows, and
// append to the device oplog. Best-effort + bounded.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireContact, WireMessage, WireThread } from "../connections/types";

const MAX_DMS = 20;
const MAX_PER_DM = 30;

async function slack<T = Record<string, unknown>>(method: string, token: string, params: Record<string, string> = {}): Promise<T> {
  const q = new URLSearchParams(params);
  const res = await fetch(`https://slack.com/api/${method}?${q}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return res.json() as Promise<T>;
}

export async function backfillSlack(
  deviceId: string, connectionId: string, userToken: string, myUserId: string,
): Promise<void> {
  const store = getStore();
  try {
    // Name map (best-effort; DMs still import without it).
    const names = new Map<string, string>();
    try {
      const users = await slack<{ members?: { id: string; real_name?: string; name?: string }[] }>(
        "users.list", userToken, { limit: "200" });
      for (const u of users.members ?? []) names.set(u.id, u.real_name || u.name || u.id);
    } catch { /* names optional */ }

    const ims = await slack<{ channels?: { id: string; user?: string }[] }>(
      "conversations.list", userToken, { types: "im", limit: String(MAX_DMS) });

    const contacts = new Map<string, WireContact>();
    const threads = new Map<string, WireThread>();
    const messages: WireMessage[] = [];

    for (const im of ims.channels ?? []) {
      const partnerId = im.user;
      const partnerName = partnerId ? (names.get(partnerId) ?? null) : null;
      const history = await slack<{ messages?: { user?: string; text?: string; ts?: string }[] }>(
        "conversations.history", userToken, { channel: im.id, limit: String(MAX_PER_DM) });

      if (partnerId) {
        contacts.set(partnerId, { platform: "slack", handle: partnerId, displayName: partnerName, isMe: false });
      }
      threads.set(im.id, {
        platform: "slack", platformThreadID: im.id,
        title: partnerName, isGroup: false,
        lastMessageAt: tsToISO(history.messages?.[0]?.ts),
      });
      for (const m of history.messages ?? []) {
        if (!m.ts) continue;
        const isFromMe = m.user === myUserId;
        messages.push({
          platform: "slack", platformMessageID: `${im.id}:${m.ts}`, platformThreadID: im.id,
          senderHandle: isFromMe ? null : (m.user ?? null),
          isFromMe, text: String(m.text ?? ""), sentAt: tsToISO(m.ts), readAt: null,
        });
      }
    }

    const seq = store.appendRows(deviceId, {
      contacts: [...contacts.values()], threads: [...threads.values()], messages,
    });
    if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
    finish(deviceId, connectionId);
  } catch (err) {
    store.setConnectionStatus(connectionId, "degraded");
    publish(deviceId, { type: "connection.status", platform: "slack", status: "degraded", connectionId });
    console.error(`[slack backfill] failed:`, (err as Error).message);
  }
}

function tsToISO(ts: string | undefined): string {
  if (!ts) return new Date(0).toISOString();
  return new Date(Number(ts.split(".")[0]) * 1000).toISOString();
}

function finish(deviceId: string, connectionId: string) {
  const store = getStore();
  store.setConnectionStatus(connectionId, "connected", 1);
  publish(deviceId, { type: "connection.status", platform: "slack", status: "connected", connectionId });
  publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
}
