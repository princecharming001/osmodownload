// Live X (Twitter) DM import. With the user's access token we page recent
// `dm_events`, normalize each MessageCreate to a wire row, and append to the
// device oplog — same shape the app already ingests for every other platform.
// Bounded so a huge DM history can't run forever on first import.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireContact, WireMessage, WireThread } from "../connections/types";
import { backfillScope, envInt } from "../connections/scope";

const PAGE_SIZE = 100;
const MAX_EVENTS_DEFAULT = 1000;   // absolute ceiling (OSMO_X_MAX_EVENTS)
const API = "https://api.x.com/2";

interface XUser { id: string; name?: string; username?: string; profile_image_url?: string }
interface XDMEvent {
  id: string;
  event_type?: string;
  text?: string;
  created_at?: string;
  sender_id?: string;
  dm_conversation_id?: string;
}

export async function backfillX(deviceId: string, connectionId: string, accessToken: string): Promise<void> {
  const store = getStore();
  const auth = { Authorization: `Bearer ${accessToken}` };

  try {
    // Who am I (to mark isFromMe)?
    const me = await fetch(`${API}/users/me`, { headers: auth })
      .then((r) => r.json()).catch(() => null);
    const myId = String(me?.data?.id ?? "");

    // Only import DMs on/after the configured backfill window.
    const sinceMs = Date.now() - backfillScope().sinceMs;

    const contacts = new Map<string, WireContact>();
    const threads = new Map<string, WireThread>();
    const messages: WireMessage[] = [];

    const maxEvents = envInt("OSMO_X_MAX_EVENTS", MAX_EVENTS_DEFAULT);
    let paginationToken: string | undefined;
    let fetched = 0;
    while (fetched < maxEvents) {
      // User hit "Stop": the connection was flipped off "backfilling" — bail.
      if (store.connectionById(connectionId)?.status !== "backfilling") break;
      const q = new URLSearchParams({
        "dm_event.fields": "id,text,event_type,created_at,sender_id,dm_conversation_id",
        "expansions": "sender_id",
        "user.fields": "name,username,profile_image_url",
        "max_results": String(PAGE_SIZE),
      });
      if (paginationToken) q.set("pagination_token", paginationToken);

      const res = await fetch(`${API}/dm_events?${q}`, { headers: auth });
      if (!res.ok) break;
      const page = await res.json();
      const events: XDMEvent[] = page.data ?? [];
      const users: XUser[] = page.includes?.users ?? [];
      const userById = new Map(users.map((u) => [u.id, u]));

      for (const ev of events) {
        fetched++;
        if (ev.event_type !== "MessageCreate" || !ev.text || !ev.dm_conversation_id) continue;
        const sentAt = ev.created_at ?? new Date().toISOString();
        if (Date.parse(sentAt) < sinceMs) continue;

        const convId = ev.dm_conversation_id;
        const senderId = ev.sender_id ?? "";
        const isFromMe = Boolean(myId && senderId === myId);
        const user = userById.get(senderId);
        const handle = user?.username ?? senderId;
        const name = user?.name ?? handle;

        if (!isFromMe && senderId) {
          // X returns a 48x48 "_normal" avatar; "_400x400" is a crisper crop the
          // proxy can cache. Non-connections get a photo just like connections.
          const avatarUrl = user?.profile_image_url?.replace("_normal.", "_400x400.") ?? null;
          contacts.set(handle, { platform: "x", handle, displayName: name, avatarUrl, isMe: false });
          // Title the thread after the other participant.
          threads.set(convId, {
            platform: "x", platformThreadID: convId, providerThreadID: convId,
            title: name, isGroup: false, lastMessageAt: sentAt,
          });
        } else if (!threads.has(convId)) {
          threads.set(convId, {
            platform: "x", platformThreadID: convId, providerThreadID: convId,
            title: "Direct message", isGroup: false, lastMessageAt: sentAt,
          });
        }

        messages.push({
          platform: "x", platformMessageID: ev.id, platformThreadID: convId,
          senderHandle: isFromMe ? null : handle,
          isFromMe, text: ev.text, sentAt, readAt: null,
          attachments: [],
        });
      }

      paginationToken = page.meta?.next_token;
      if (!paginationToken || events.length === 0) break;
    }

    const seq = store.appendRows(deviceId, {
      contacts: [...contacts.values()], threads: [...threads.values()], messages,
    });
    if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
    finish(deviceId, connectionId);
  } catch (err) {
    if (store.connectionById(connectionId)?.status === "backfilling") {
      store.setConnectionStatus(connectionId, "degraded");
      publish(deviceId, { type: "connection.status", platform: "x", status: "degraded", connectionId });
    }
    console.error(`[x backfill] failed:`, (err as Error).message);
  }
}

function finish(deviceId: string, connectionId: string) {
  const store = getStore();
  // Terminal flip ONLY from "backfilling": a user pause (or disconnect) that
  // made the import bail must not be overridden back to "connected" here.
  if (store.connectionById(connectionId)?.status === "backfilling") {
    store.touchConnection(connectionId, { lastSyncAt: new Date().toISOString() });
    store.setConnectionStatus(connectionId, "connected", 1);
    publish(deviceId, { type: "connection.status", platform: "x", status: "connected", connectionId });
  }
  publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
}
