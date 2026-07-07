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
import { backfillScope, makeConversationGate } from "./scope";

// The TIME cutoff (from the configured scope: 60d full / 15d demo) is the real
// stop; MAX_MESSAGE_PAGES is only a runaway safety ceiling (250/page × 200 =
// 50k) so a hyperactive account can't page forever.
const MAX_MESSAGE_PAGES = 200;

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
    let chats: Map<string, { title: string | null; isGroup: boolean; providerId: string | null }> = new Map();
    try {
      const page = await unipile.listChats(accountId);
      chats = chatIndex(page.chats);
    } catch { /* titles are optional */ }

    // 2. Page messages, normalize, append — until we've covered the scope's
    //    window (60d full / 15d demo), the provider runs out of pages, or the
    //    safety ceiling trips. In demo scope, a conversation gate keeps only the
    //    5 most recently active chats (stream is newest-first, so first-seen =
    //    most recent). Ingest is idempotent (dedup on platform+messageID), so
    //    overlapping pages / re-runs never duplicate.
    const scope = backfillScope();
    const gate = makeConversationGate(scope.maxConversations);
    const cutoff = Date.now() - scope.sinceMs;
    const cutoffISO = new Date(cutoff).toISOString();

    // Attendee directory, fetched lazily per admitted chat: the ONLY reliable
    // source of names + avatars on LinkedIn/Instagram, where message payloads
    // carry raw attendee ids (the raw-id-as-title bug). Bounded so a huge
    // full-scope import can't turn into thousands of extra calls.
    const attendeeName = new Map<string, { name: string | null; avatar: string | null }>();
    const selfIds = new Set<string>();
    const otherNameByChat = new Map<string, { name: string | null; avatar: string | null }>();
    const attendeesFetched = new Set<string>();
    const MAX_ATTENDEE_FETCHES = 60;
    async function indexAttendees(chatId: string): Promise<void> {
      if (attendeesFetched.has(chatId) || attendeesFetched.size >= MAX_ATTENDEE_FETCHES) return;
      attendeesFetched.add(chatId);
      try {
        for (const att of await unipile.listChatAttendees(chatId)) {
          for (const id of att.ids) {
            if (att.isSelf) { selfIds.add(id); continue; }
            attendeeName.set(id, { name: att.name, avatar: att.pictureUrl });
          }
          if (!att.isSelf && !otherNameByChat.has(chatId)) {
            otherNameByChat.set(chatId, { name: att.name, avatar: att.pictureUrl });
          }
        }
      } catch { /* names are enrichment — messages still import without them */ }
    }

    let cursor: string | undefined;
    for (let pageNo = 0; pageNo < MAX_MESSAGE_PAGES; pageNo++) {
      const { messages, cursor: next } = await unipile.listMessages(accountId, cursor, cutoffISO);
      if (messages.length === 0) break;

      const bundles = (messages
        .map((m) => normalizeUnipileMessage(m, platform, chats))
        .filter(Boolean) as RowBundle[])
        .filter((b) => {
          const tid = b.messages?.[0]?.platformThreadID;
          return tid ? gate(tid) : true;
        });

      // Enrich with attendee names/avatars + fix 1:1 titles + self-attribution.
      for (const b of bundles) {
        const tid = b.messages?.[0]?.platformThreadID;
        if (tid) await indexAttendees(tid);
        for (const c of b.contacts ?? []) {
          const hit = attendeeName.get(c.handle);
          if (hit) {
            c.displayName = c.displayName ?? hit.name;
            c.avatarUrl = c.avatarUrl ?? hit.avatar;
          }
        }
        for (const t of b.threads ?? []) {
          if (!t.isGroup && (t.title == null || t.title === "")) {
            t.title = otherNameByChat.get(t.platformThreadID)?.name ?? t.title;
          }
        }
        for (const m of b.messages ?? []) {
          // A sender id that turns out to be OUR OWN attendee id → from me
          // (some providers omit is_sender on historical rows).
          if (!m.isFromMe && m.senderHandle && selfIds.has(m.senderHandle)) {
            m.isFromMe = true;
            m.senderHandle = null;
          }
        }
        // Drop self-contacts that slipped in as counterparties.
        if (b.contacts) b.contacts = b.contacts.filter((c) => !selfIds.has(c.handle));
      }
      const merged = mergeBundles(bundles);
      const seq = merged ? store.appendRows(deviceId, merged) : 0;

      // Oldest message time seen on THIS page (direction-agnostic: works whether
      // the provider pages newest→oldest or the reverse). Append the boundary
      // page first, THEN stop, so nothing on the 60-day edge is dropped.
      let oldestMs = Date.now();
      for (const b of bundles) {
        for (const m of b.messages ?? []) {
          const t = Date.parse(m.sentAt);
          if (!Number.isNaN(t) && t < oldestMs) oldestMs = t;
        }
      }

      // Progress by history depth covered (total is unknown), not page count.
      const progress = Math.min(0.95, (Date.now() - oldestMs) / scope.sinceMs);
      store.setConnectionStatus(accountId, "backfilling", progress);
      publish(deviceId, { type: "backfill.progress", platform, progress });
      if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });

      if (oldestMs < cutoff) break;   // reached ~2 months back
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
