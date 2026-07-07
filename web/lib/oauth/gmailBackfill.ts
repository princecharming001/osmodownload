// Live Gmail history import. With the user's access token we page recent
// messages, pull each one's FULL payload (body + headers + attachment
// metadata), normalize to wire rows, and append to the device oplog.
// Best-effort + bounded so a huge mailbox can't run forever on first import.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireAttachment, WireContact, WireMessage, WireThread } from "../connections/types";
import { backfillScope, makeConversationGate } from "../connections/scope";
import { kindFromMime } from "../connections/attachments";

const PAGE_SIZE = 100;
const MAX_MESSAGES = 300;   // absolute ceiling, bounded for speed
const BODY_CHAR_CAP = 4000; // keeps oplog rows bounded even for long threads

/** Gmail search window from the configured scope (60d full / 15d demo). */
function historyQuery(): string {
  const days = Math.max(1, Math.round(backfillScope().sinceMs / 86_400_000));
  return `newer_than:${days}d`;
}

/** Parse `Name <email@x>` → {name, email}. */
function parseAddress(v: string | undefined): { name: string | null; email: string | null } {
  if (!v) return { name: null, email: null };
  const m = v.match(/^\s*(?:"?([^"<]*)"?\s)?<?([^<>\s]+@[^<>\s]+)>?/);
  return { name: (m?.[1]?.trim() || null), email: (m?.[2]?.trim().toLowerCase() || null) };
}

// ---------------------------------------------------------------------------
// MIME body extraction — Gmail's format=full returns a tree of `parts`; a
// simple message has none and carries its body directly on the root.

export interface GmailHeader { name: string; value: string }
export interface GmailAttachmentMeta {
  attachmentId: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
}
export interface GmailPart {
  mimeType?: string;
  filename?: string;
  headers?: GmailHeader[];
  body?: { data?: string; attachmentId?: string; size?: number };
  parts?: GmailPart[];
}

function decodeBase64Url(data: string): string {
  return Buffer.from(data, "base64url").toString("utf-8");
}

/** Strip an HTML body down to readable text — a last-resort fallback when a
    message has no text/plain alternative (marketing mail loves this). */
export function stripHtml(html: string): string {
  return html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Walk a Gmail MIME tree, unconditionally (arbitrary multipart/alternative-
    inside-multipart/mixed nesting): first text/plain leaf wins (RFC 2046 lists
    alternatives least-preferred-first, so plain text precedes html), falling
    back to text/html; attachment leaves are collected on the way. A message
    with no `parts` at all is handled for free — `visit` runs on the root part
    itself before ever touching `.parts`. */
export function walkParts(payload: GmailPart): { text: string | null; html: string | null; attachments: GmailAttachmentMeta[] } {
  let text: string | null = null;
  let html: string | null = null;
  const attachments: GmailAttachmentMeta[] = [];

  function visit(part: GmailPart) {
    const mime = part.mimeType ?? "";
    if (part.filename && part.body?.attachmentId) {
      attachments.push({
        attachmentId: part.body.attachmentId,
        filename: part.filename,
        mimeType: mime || "application/octet-stream",
        sizeBytes: part.body.size ?? 0,
      });
      return; // an attachment leaf is never also inline body text
    }
    if (mime === "text/plain" && part.body?.data && text === null) {
      text = decodeBase64Url(part.body.data);
    } else if (mime === "text/html" && part.body?.data && html === null) {
      html = decodeBase64Url(part.body.data);
    }
    for (const child of part.parts ?? []) visit(child);
  }
  visit(payload);
  return { text, html, attachments };
}

// ---------------------------------------------------------------------------
// Automated-sender detection — feeds WireThread.automatedHint.

const AUTOMATED_SENDER_DOMAINS = new Set([
  "mail.instagram.com", "facebookmail.com", "e.paypal.com", "substack.com",
  "mailchimp.com", "sendgrid.net", "amazonses.com", "mailgun.org",
  "notifications.google.com", "e.newsletter.com", "notify.slack.com",
]);

const AUTOMATED_LOCALPART_MARKERS = [
  "no-reply", "noreply", "donotreply", "do-not-reply", "notifications",
  "notification", "notify", "alert", "newsletter", "mailer-daemon", "automated",
];

/** True when the message is a bulk/automated send — checked via the headers
    real mail clients use to auto-file it (List-Unsubscribe/Precedence/List-Id)
    plus sender-shape heuristics that catch what those headers miss (a plain
    "instagram.alerts@mail.instagram.com" carries none of them). */
export function automatedSignals(headers: GmailHeader[], fromEmail: string | null): boolean {
  const h = (n: string) => headers.find((x) => x.name.toLowerCase() === n)?.value;
  if (h("list-unsubscribe")) return true;
  const precedence = h("precedence")?.toLowerCase();
  if (precedence && ["bulk", "list", "junk"].includes(precedence)) return true;
  if (h("list-id")) return true;
  if (fromEmail) {
    const at = fromEmail.indexOf("@");
    const localpart = at >= 0 ? fromEmail.slice(0, at) : fromEmail;
    const domain = at >= 0 ? fromEmail.slice(at + 1) : "";
    const collapsed = localpart.replace(/[._-]/g, "");
    if (AUTOMATED_LOCALPART_MARKERS.some((marker) => collapsed.includes(marker))) return true;
    if (AUTOMATED_SENDER_DOMAINS.has(domain)) return true;
  }
  return false;
}

/** Gmail attachment metadata → wire rows. `remoteRef` IS the Gmail
    attachmentId — the media route re-fetches `messages/{id}/attachments/{ref}`
    with it directly, no translation needed. */
export function gmailAttachmentsToWire(attachments: GmailAttachmentMeta[]): WireAttachment[] | undefined {
  if (attachments.length === 0) return undefined;
  return attachments.map((a) => ({
    id: a.attachmentId, kind: kindFromMime(undefined, a.mimeType),
    mimeType: a.mimeType, filename: a.filename, sizeBytes: a.sizeBytes,
    remoteRef: a.attachmentId,
  }));
}

export async function backfillGmail(deviceId: string, connectionId: string, accessToken: string): Promise<void> {
  const store = getStore();
  const auth = { Authorization: `Bearer ${accessToken}` };
  const api = "https://gmail.googleapis.com/gmail/v1/users/me";

  try {
    // Who am I (to mark isFromMe)?
    const profile = await fetch(`${api}/profile`, { headers: auth }).then((r) => r.json());
    const myEmail = String(profile.emailAddress ?? "").toLowerCase();

    // Page (id, threadId) pairs — messages.list already returns both, so the
    // demo/scope gate runs BEFORE the heavier per-message fetch (quota win
    // over the old fetch-then-gate order).
    const items: { id: string; threadId: string }[] = [];
    let pageToken: string | undefined;
    while (items.length < MAX_MESSAGES) {
      const q = new URLSearchParams({ maxResults: String(PAGE_SIZE), q: historyQuery() });
      if (pageToken) q.set("pageToken", pageToken);
      const list = await fetch(`${api}/messages?${q}`, { headers: auth }).then((r) => r.json());
      for (const m of (list.messages ?? []) as { id: string; threadId: string }[]) {
        items.push({ id: m.id, threadId: m.threadId });
      }
      pageToken = list.nextPageToken;
      if (!pageToken) break;
    }
    if (items.length === 0) { finish(deviceId, connectionId); return; }

    const contacts = new Map<string, WireContact>();
    const threads = new Map<string, WireThread>();
    const messages: WireMessage[] = [];
    const gate = makeConversationGate(backfillScope().maxConversations);
    // Sticky OR: once any message in a thread trips the automated signal, the
    // whole thread stays flagged (a single automated blast shouldn't get
    // "un-flagged" by an unrelated reply landing in the same thread id).
    const automatedByThread = new Map<string, boolean>();

    for (const item of items) {
      if (!gate(item.threadId)) continue;   // gate BEFORE the format=full fetch

      const msg = await fetch(`${api}/messages/${item.id}?format=full`, { headers: auth })
        .then((r) => r.json()).catch(() => null);
      if (!msg) continue;

      const headers: GmailHeader[] = msg.payload?.headers ?? [];
      const header = (n: string) => headers.find((h) => h.name.toLowerCase() === n)?.value;
      const from = parseAddress(header("from"));
      const subject = header("subject") ?? null;
      const threadId = String(msg.threadId ?? item.id);
      const sentAt = msg.internalDate
        ? new Date(Number(msg.internalDate)).toISOString()
        : new Date().toISOString();
      const isFromMe = Boolean(from.email && myEmail && from.email === myEmail);

      const { text, html, attachments } = walkParts(msg.payload ?? {});
      const body = (text ?? (html ? stripHtml(html) : null) ?? String(msg.snippet ?? ""))
        .slice(0, BODY_CHAR_CAP);
      const wireAttachments = gmailAttachmentsToWire(attachments);

      const automated = automatedSignals(headers, from.email);
      automatedByThread.set(threadId, (automatedByThread.get(threadId) ?? false) || automated);

      if (!isFromMe && from.email) {
        contacts.set(from.email, { platform: "gmail", handle: from.email, displayName: from.name, isMe: false });
      }
      threads.set(threadId, {
        platform: "gmail", platformThreadID: threadId, providerThreadID: threadId,
        title: subject ?? from.name ?? from.email, isGroup: false, lastMessageAt: sentAt,
      });
      messages.push({
        platform: "gmail", platformMessageID: item.id, platformThreadID: threadId,
        senderHandle: isFromMe ? null : from.email,
        isFromMe, text: body, sentAt, readAt: null,
        attachments: wireAttachments,
      });
    }

    // Fold the sticky per-thread automated hint into each emitted thread row.
    for (const [tid, hint] of automatedByThread) {
      const t = threads.get(tid);
      if (t) t.automatedHint = hint;
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
