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
import { backfillScope, envInt, makeConversationGate } from "./scope";
import { deepFetchScope } from "./deepFetch";

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
    // 1. Chats → title/group index (best-effort; messages still import without
    //    it). Cursor-paged so accounts with more chats than one page (50) keep
    //    their titles; the mock returns a null cursor, so keyless stays 1 page.
    const chats: Map<string, { title: string | null; isGroup: boolean; providerId: string | null }> = new Map();
    try {
      let chatCursor: string | undefined;
      for (let chatPage = 0; chatPage < envInt("OSMO_UNIPILE_MAX_CHAT_PAGES", 10); chatPage++) {
        const page = await unipile.listChats(accountId, chatCursor);
        for (const [id, entry] of chatIndex(page.chats)) chats.set(id, entry);
        if (!page.cursor) break;
        chatCursor = page.cursor;
      }
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
    // Raised from 60 → 200 (env-tunable): the cap was silently leaving
    // non-connections nameless past the first ~60 chats. Names are cheap; this
    // is the main lever for "why is this person just a raw id / monogram".
    const MAX_ATTENDEE_FETCHES = envInt("OSMO_MAX_ATTENDEE_FETCHES", 200);
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

    // Enrich a batch with attendee names/avatars + fix 1:1 titles + self-
    // attribution (shared by the sweep pages and the deep per-chat pass).
    async function enrichBundles(bundles: RowBundle[]): Promise<void> {
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
    }

    // First N DISTINCT chat ids on the newest-first stream = the N most
    // recently active conversations → the deep per-chat pass below.
    const deep = deepFetchScope();
    const deepChatIds = new Set<string>();

    let cursor: string | undefined;
    for (let pageNo = 0; pageNo < MAX_MESSAGE_PAGES; pageNo++) {
      // User hit "Stop": the connection was flipped off "backfilling" — bail and
      // keep whatever's imported so far.
      if (store.connectionById(accountId)?.status !== "backfilling") break;
      const { messages, cursor: next } = await unipile.listMessages(accountId, cursor, cutoffISO);
      if (messages.length === 0) break;
      // Loop guard: a provider echoing the SAME cursor back would re-fetch this
      // page forever (ingest dedups, so it looks like silent spinning, burning
      // upstream quota until the page ceiling). Repeat cursor → done.
      if (next && next === cursor) break;

      const normalized = messages
        .map((m) => normalizeUnipileMessage(m, platform, chats))
        .filter(Boolean) as RowBundle[];
      for (const b of normalized) {
        const tid = b.messages?.[0]?.platformThreadID;
        if (tid && deepChatIds.size < deep.conversations) deepChatIds.add(tid);
      }
      const bundles = normalized.filter((b) => {
        const tid = b.messages?.[0]?.platformThreadID;
        return tid ? gate(tid) : true;
      });

      // Enrich with attendee names/avatars + fix 1:1 titles + self-attribution.
      await enrichBundles(bundles);
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
      // Don't re-arm "backfilling" if the user stopped mid-page (would defeat the
      // loop-top bail on the next iteration).
      if (store.connectionById(accountId)?.status === "backfilling") {
        store.setConnectionStatus(accountId, "backfilling", progress);
      }
      publish(deviceId, { type: "backfill.progress", platform, progress });
      if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });

      if (oldestMs < cutoff) break;   // reached the scope window's edge
      if (!next) break;
      cursor = next;
    }

    // 3. Deep pass: those top conversations get their WHOLE chat paged to the
    //    configured depth via the per-chat endpoint — full context beyond the
    //    account-wide sweep's window slice. The conversation gate is
    //    deliberately bypassed: these ARE the most recent chats. Best-effort
    //    per chat (the sweep already imported the recent slice). Mock returns
    //    an empty page, so keyless is untouched.
    for (const chatId of deepChatIds) {
      if (store.connectionById(accountId)?.status !== "backfilling") break;
      try {
        const collected: RowBundle[] = [];
        let msgCursor: string | undefined;
        // Page ceiling: `collected` only grows on normalizable messages, so a
        // provider feeding pages of junk rows with fresh cursors would spin
        // this while-loop forever without a hard bound.
        const maxPages = Math.max(10, Math.ceil(deep.messagesPerConversation / 10));
        for (let page_ = 0; page_ < maxPages && collected.length < deep.messagesPerConversation; page_++) {
          const page = await unipile.listChatMessages(chatId, msgCursor);
          if (page.messages.length === 0) break;
          for (const m of page.messages) {
            if (collected.length >= deep.messagesPerConversation) break;
            const b = normalizeUnipileMessage(m, platform, chats);
            if (b) collected.push(b);
          }
          // No cursor, or the SAME cursor echoed back (would loop) → done.
          if (!page.cursor || page.cursor === msgCursor) break;
          msgCursor = page.cursor;
        }
        if (collected.length === 0) continue;
        await enrichBundles(collected);
        const merged = mergeBundles(collected);
        const seq = merged ? store.appendRows(deviceId, merged) : 0;
        if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
      } catch { /* deep context is enrichment — never fails the backfill */ }
    }

    // Terminal flip ONLY from "backfilling": if the user paused (or the
    // connection was removed) mid-import, the bail-out above must not be
    // overridden back to "connected" here.
    if (store.connectionById(accountId)?.status === "backfilling") {
      store.touchConnection(accountId, { lastSyncAt: new Date().toISOString() });
      store.setConnectionStatus(accountId, "connected", 1);
      publish(deviceId, { type: "connection.status", platform, status: "connected", connectionId: accountId });
    }
    // Final doorbell with the current max seq (empty append = read-only seq peek).
    publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
  } catch (err) {
    // Drive the status to a terminal state so it never sticks on "backfilling"
    // forever — but only from "backfilling" (a pause that raced the throw must
    // stay paused).
    if (store.connectionById(accountId)?.status === "backfilling") {
      store.setConnectionStatus(accountId, "degraded");
      publish(deviceId, {
        type: "connection.status", platform, status: "degraded", connectionId: accountId,
      });
    }
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
