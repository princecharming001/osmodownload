// Live Gmail history import. With the user's access token we page recent
// messages, pull each one's metadata + snippet, normalize to wire rows, and
// append to the device oplog. Best-effort + bounded so a huge mailbox can't run
// forever on the first import.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireContact, WireMessage, WireThread } from "../connections/types";

const MAX_MESSAGES = 40;

/** Parse `Name <email@x>` → {name, email}. */
function parseAddress(v: string | undefined): { name: string | null; email: string | null } {
  if (!v) return { name: null, email: null };
  const m = v.match(/^\s*(?:"?([^"<]*)"?\s)?<?([^<>\s]+@[^<>\s]+)>?/);
  return { name: (m?.[1]?.trim() || null), email: (m?.[2]?.trim().toLowerCase() || null) };
}

export async function backfillGmail(deviceId: string, connectionId: string, accessToken: string): Promise<void> {
  const store = getStore();
  const auth = { Authorization: `Bearer ${accessToken}` };
  const api = "https://gmail.googleapis.com/gmail/v1/users/me";

  try {
    // Who am I (to mark isFromMe)?
    const profile = await fetch(`${api}/profile`, { headers: auth }).then((r) => r.json());
    const myEmail = String(profile.emailAddress ?? "").toLowerCase();

    const list = await fetch(`${api}/messages?maxResults=${MAX_MESSAGES}`, { headers: auth })
      .then((r) => r.json());
    const ids: string[] = (list.messages ?? []).map((m: { id: string }) => m.id);
    if (ids.length === 0) { finish(deviceId, connectionId); return; }

    const contacts = new Map<string, WireContact>();
    const threads = new Map<string, WireThread>();
    const messages: WireMessage[] = [];

    for (const id of ids) {
      const msg = await fetch(
        `${api}/messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date`,
        { headers: auth },
      ).then((r) => r.json()).catch(() => null);
      if (!msg) continue;

      const headers: { name: string; value: string }[] = msg.payload?.headers ?? [];
      const header = (n: string) => headers.find((h) => h.name.toLowerCase() === n)?.value;
      const from = parseAddress(header("from"));
      const subject = header("subject") ?? null;
      const threadId = String(msg.threadId ?? id);
      const sentAt = msg.internalDate
        ? new Date(Number(msg.internalDate)).toISOString()
        : new Date().toISOString();
      const isFromMe = Boolean(from.email && myEmail && from.email === myEmail);

      if (!isFromMe && from.email) {
        contacts.set(from.email, { platform: "gmail", handle: from.email, displayName: from.name, isMe: false });
      }
      threads.set(threadId, {
        platform: "gmail", platformThreadID: threadId,
        title: subject ?? from.name ?? from.email, isGroup: false, lastMessageAt: sentAt,
      });
      messages.push({
        platform: "gmail", platformMessageID: id, platformThreadID: threadId,
        senderHandle: isFromMe ? null : from.email,
        isFromMe, text: String(msg.snippet ?? ""), sentAt, readAt: null,
      });
    }

    const seq = store.appendRows(deviceId, {
      contacts: [...contacts.values()], threads: [...threads.values()], messages,
    });
    if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
    finish(deviceId, connectionId);
  } catch (err) {
    store.setConnectionStatus(connectionId, "degraded");
    publish(deviceId, { type: "connection.status", platform: "gmail", status: "degraded", connectionId });
    console.error(`[gmail backfill] failed:`, (err as Error).message);
  }
}

function finish(deviceId: string, connectionId: string) {
  const store = getStore();
  store.setConnectionStatus(connectionId, "connected", 1);
  publish(deviceId, { type: "connection.status", platform: "gmail", status: "connected", connectionId });
  publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
}
