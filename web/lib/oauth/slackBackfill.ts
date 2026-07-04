// Live Slack history import. With the user token we list the user's DMs, page
// each one's recent messages, resolve sender names, normalize to wire rows, and
// append to the device oplog. Best-effort + bounded.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireContact, WireMessage, WireThread } from "../connections/types";

const MAX_DMS = 25;
const PER_PAGE = 100;
const MAX_PER_DM = 300;                       // ~2 months of an active DM
const OLDEST_TS = () => String(Math.floor(Date.now() / 1000) - 60 * 24 * 3600);  // 60 days ago

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
    // Name + avatar map (best-effort; DMs still import without it).
    const names = new Map<string, string>();
    const avatars = new Map<string, string>();
    try {
      const users = await slack<{
        members?: { id: string; real_name?: string; name?: string;
                    profile?: { image_192?: string; image_512?: string } }[];
      }>("users.list", userToken, { limit: "200" });
      for (const u of users.members ?? []) {
        names.set(u.id, u.real_name || u.name || u.id);
        const img = u.profile?.image_512 || u.profile?.image_192;
        if (img) avatars.set(u.id, img);
      }
    } catch { /* names optional */ }

    const ims = await slack<{ channels?: { id: string; user?: string }[] }>(
      "conversations.list", userToken, { types: "im", limit: String(MAX_DMS) });

    const contacts = new Map<string, WireContact>();
    const threads = new Map<string, WireThread>();
    const messages: WireMessage[] = [];

    const oldest = OLDEST_TS();
    for (const im of ims.channels ?? []) {
      const partnerId = im.user;
      const partnerName = partnerId ? (names.get(partnerId) ?? null) : null;

      // Page this DM's history back ~2 months (bounded by MAX_PER_DM).
      const dmMessages: { user?: string; text?: string; ts?: string }[] = [];
      let cursor: string | undefined;
      while (dmMessages.length < MAX_PER_DM) {
        const params: Record<string, string> = { channel: im.id, limit: String(PER_PAGE), oldest };
        if (cursor) params.cursor = cursor;
        const page = await slack<{
          messages?: { user?: string; text?: string; ts?: string }[];
          response_metadata?: { next_cursor?: string };
        }>("conversations.history", userToken, params);
        dmMessages.push(...(page.messages ?? []));
        cursor = page.response_metadata?.next_cursor;
        if (!cursor) break;
      }

      if (partnerId) {
        contacts.set(partnerId, {
          platform: "slack", handle: partnerId, displayName: partnerName,
          avatarUrl: avatars.get(partnerId) ?? null, isMe: false,
        });
      }
      threads.set(im.id, {
        platform: "slack", platformThreadID: im.id,
        title: partnerName, isGroup: false,
        lastMessageAt: tsToISO(dmMessages[0]?.ts),
      });
      for (const m of dmMessages) {
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
