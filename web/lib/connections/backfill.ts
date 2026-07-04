// Live-mode history import. On a fresh Unipile connection we page the account's
// chats (for titles) then its messages, normalize each to wire rows, append to
// the device oplog, and emit progress. The app's cursor-pull then delivers the
// whole history into the local encrypted store. Best-effort + bounded so a huge
// account can't run forever on the first import.

import { getStore } from "./memoryStore";
import { publish } from "./events";
import type { Platform, WireContact, WireMessage, WireThread } from "./types";
import { getUnipile } from "../unipile/client";
import { chatIndex, normalizeUnipileMessage } from "../unipile/normalize";
import type { RowBundle } from "./memoryStore";

const MAX_MESSAGE_PAGES = 20;   // ~2000 messages — well over 2 months for DMs

/** Import an account's recent history into the device oplog. Fire-and-forget
    from the notify callback; failures leave the connection `backfilling` and the
    reconciliation poller retries. */
export async function backfillConnection(opts: {
  deviceId: string;
  accountId: string;
  platform: Platform;
}): Promise<void> {
  const { deviceId, accountId, platform } = opts;
  const store = getStore();
  const unipile = getUnipile();

  try {
    // 1. Chats → title/group index (best-effort; messages still import without it).
    let chats: Map<string, { title: string | null; isGroup: boolean }> = new Map();
    try {
      const page = await unipile.listChats(accountId);
      chats = chatIndex(page.chats);
    } catch { /* titles are optional */ }

    // 2. Page messages, normalize, append.
    let cursor: string | undefined;
    for (let pageNo = 0; pageNo < MAX_MESSAGE_PAGES; pageNo++) {
      const { messages, cursor: next } = await unipile.listMessages(accountId, cursor);
      if (messages.length === 0) break;

      const merged = mergeBundles(
        messages.map((m) => normalizeUnipileMessage(m, platform, chats)).filter(Boolean) as RowBundle[],
      );
      const seq = merged ? store.appendRows(deviceId, merged) : 0;

      // Coarse progress (we don't know the total; report the arc).
      const progress = Math.min(0.95, (pageNo + 1) / MAX_MESSAGE_PAGES);
      store.setConnectionStatus(accountId, "backfilling", progress);
      publish(deviceId, { type: "backfill.progress", platform, progress });
      if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });

      if (!next) break;
      cursor = next;
    }

    store.setConnectionStatus(accountId, "connected", 1);
    publish(deviceId, { type: "connection.status", platform, status: "connected", connectionId: accountId });
    // Final doorbell with the current max seq (empty append = read-only seq peek).
    publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
  } catch (err) {
    // Leave status `backfilling`; reconciliation retries. Surface a degraded
    // state so the UI can nudge a reconnect if it never recovers.
    store.setConnectionStatus(accountId, "degraded");
    publish(deviceId, {
      type: "connection.status", platform, status: "degraded", connectionId: accountId,
    });
    console.error(`[backfill] ${platform}/${accountId} failed:`, (err as Error).message);
  }
}

/** Fold per-message bundles into one, de-duping threads/contacts by key. */
function mergeBundles(bundles: RowBundle[]): RowBundle | null {
  if (bundles.length === 0) return null;
  const contacts = new Map<string, WireContact>();
  const threads = new Map<string, WireThread>();
  const messages: WireMessage[] = [];
  for (const b of bundles) {
    for (const c of b.contacts ?? []) contacts.set(`${c.platform}:${c.handle}`, c);
    for (const t of b.threads ?? []) threads.set(`${t.platform}:${t.platformThreadID}`, t);
    messages.push(...(b.messages ?? []));
  }
  return { contacts: [...contacts.values()], threads: [...threads.values()], messages };
}
