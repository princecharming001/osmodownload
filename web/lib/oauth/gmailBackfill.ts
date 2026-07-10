// Live Gmail history import. With the user's access token we page recent
// messages, pull each one's FULL payload (body + headers + attachment
// metadata), normalize to wire rows, and append to the device oplog.
// Best-effort + bounded so a huge mailbox can't run forever on first import.

import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import type { WireAttachment, WireContact, WireMessage, WireThread } from "../connections/types";
import { backfillScope, envInt, makeConversationGate } from "../connections/scope";
import { deepFetchScope } from "../connections/deepFetch";
import { kindFromMime } from "../connections/attachments";

const PAGE_SIZE = 100;
const MAX_MESSAGES_DEFAULT = 1000; // absolute sweep ceiling (OSMO_GMAIL_MAX_MESSAGES)
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

/** ESP / event-platform sending domains: mail DKIM-signed by (or bounced
    through) one of these is machine-sent by definition. Suffix-matched, so
    "bounces.sendgrid.net" counts too. */
export const ESP_DOMAINS = [
  "sendgrid.net", "mailgun.org", "amazonses.com", "postmarkapp.com",
  "customeriomail.com", "klaviyomail.com", "braze.com", "intercom-mail.com",
  "hubspotemail.net", "mandrillapp.com", "mcsv.net", "rsgsv.net",
  "sparkpostmail.com", "mailjet.com", "brevo.com", "luma-mail.com",
  "lu.ma", "partiful.com", "eventbrite.com",
];

// Substring markers: safe because no human localpart contains one whole.
const AUTOMATED_LOCALPART_MARKERS = [
  "no-reply", "noreply", "donotreply", "do-not-reply", "notifications",
  "notification", "notify", "alert", "newsletter", "mailer-daemon", "automated",
];

/** Unambiguous machine-mailbox localparts matched EXACTLY on the collapsed
    (dots/dashes/underscores removed) localpart — exact, never substring, so
    "hi" can't swallow "hillary". A hit here is decisive: no human mails
    personally from receipts@ or verification@. */
export const HARD_LOCALPART_EXACT = new Set([
  "notifications", "billing", "receipts", "receipt", "orders", "order",
  "invoices", "invoice", "verify", "verification", "confirm", "confirmation",
  "security", "reminders", "reminder", "digest", "bookings", "booking",
  "reservations", "promotions", "promo", "offers", "rewards", "marketing",
  "newsletter", "news", "admin", "accounts", "account", "registration",
  "register", "invites", "invite", "invitations", "calendar", "updates",
  "alerts",
]);

/** Plausibly-HUMAN service localparts — a founder really does mail personally
    from hello@theirname.com, and events@ can be a person organizing one. A
    soft hit alone must NEVER flag; it only flags alongside a second machine
    signal (bulk header, ESP domain, sending-subdomain prefix, or a templated
    subject from a non-personal domain) — and every one of those second signals
    is already decisive on its own below, so this set intentionally carries no
    independent weight. Kept exported so the hard/soft split is explicit. */
export const SOFT_LOCALPART_EXACT = new Set([
  "hello", "hi", "hey", "team", "info", "contact", "press", "sales",
  "careers", "jobs", "community", "members", "membership", "welcome",
  "feedback", "survey", "success", "support", "help", "events", "event",
]);

/** Sending-infrastructure first labels ("mail.instagram.com", "e.paypal.com").
    Only meaningful on a subdomain (≥3 labels) — nobody @mail.com gets flagged. */
const AUTOMATED_SUBDOMAIN_LABELS = new Set([
  "mail", "e", "em", "email", "marketing", "news", "newsletter", "notify",
  "notifications", "updates", "alerts", "mailer", "bounce", "mg",
]);

/** Free personal-mail domains — a templated-looking subject from one of these
    stays human (mom really does write "Your photos from the lake"). Mirrors
    the Swift classifier's list. */
const PERSONAL_MAIL_DOMAINS = new Set([
  "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "outlook.com",
  "hotmail.com", "icloud.com", "me.com", "mac.com", "aol.com", "hey.com",
  "fastmail.com", "fastmail.fm", "proton.me", "protonmail.com",
  "live.com", "msn.com",
]);

/** Personal-mail check, suffix-tolerant for Yahoo's ccTLD zoo (yahoo.de,
    yahoo.com.au, …). */
function isPersonalMailDomain(domain: string): boolean {
  return PERSONAL_MAIL_DOMAINS.has(domain) || domain.startsWith("yahoo.");
}

const TEMPLATED_SUBJECT_RES = [
  /^(your|welcome to|verify|confirm|reset|receipt|invoice|order|registration|reminder|action required|invitation|you're invited|thanks for|get started|complete your|activate|new sign.?in|security alert)\b/i,
  /\bapproved for\b/i,
  /\bis ready\b/i,
  /\bhas shipped\b/i,
  /\border #/i,
];

/** Casual human markers that veto the templated-subject signal ("your package
    arrived lol" is a friend, not a shipping bot). */
const CASUAL_SUBJECT_RE = /\blol\b|\bhaha\b|\bomg\b|\?\?/i;

/** True when a subject line reads like a transactional/marketing template. */
export function templatedSubject(s: string): boolean {
  if (CASUAL_SUBJECT_RE.test(s)) return false;
  return TEMPLATED_SUBJECT_RES.some((re) => re.test(s.trim()));
}

/** Suffix-match a domain against the ESP list ("em1234.lu.ma" → lu.ma). */
function isESPDomain(domain: string | undefined): boolean {
  if (!domain) return false;
  const d = domain.toLowerCase();
  return ESP_DOMAINS.some((esp) => d === esp || d.endsWith(`.${esp}`));
}

/** True when the message is a bulk/automated send — checked via the headers
    real mail clients use to auto-file it (List-Unsubscribe/Precedence/List-Id/
    Auto-Submitted/Feedback-ID…), ESP fingerprints in the signing/bounce path,
    plus sender-shape and subject-template heuristics that catch what those
    headers miss (a plain "instagram.alerts@mail.instagram.com" carries none
    of them). */
export function automatedSignals(headers: GmailHeader[], fromEmail: string | null, subject?: string | null): boolean {
  const h = (n: string) => headers.find((x) => x.name.toLowerCase() === n)?.value;
  if (h("list-unsubscribe")) return true;
  if (h("list-unsubscribe-post")) return true;
  const precedence = h("precedence")?.toLowerCase();
  if (precedence && ["bulk", "list", "junk"].includes(precedence)) return true;
  if (h("list-id")) return true;
  // RFC 3834: any Auto-Submitted value other than "no" is machine-generated.
  const autoSubmitted = h("auto-submitted")?.toLowerCase();
  if (autoSubmitted && autoSubmitted !== "no") return true;
  if (h("feedback-id")) return true;              // ESP campaign tracking
  if (h("x-auto-response-suppress")) return true; // "don't auto-reply to me" = a bot
  // ESP fingerprints: DKIM d= signing domains + the Return-Path bounce domain.
  for (const dkim of headers.filter((x) => x.name.toLowerCase() === "dkim-signature")) {
    if (isESPDomain(dkim.value.match(/\bd=([^;\s]+)/i)?.[1])) return true;
  }
  if (isESPDomain(h("return-path")?.match(/@([^>\s]+)>?\s*$/)?.[1])) return true;
  if (fromEmail) {
    const at = fromEmail.indexOf("@");
    const localpart = at >= 0 ? fromEmail.slice(0, at) : fromEmail;
    const domain = (at >= 0 ? fromEmail.slice(at + 1) : "").toLowerCase();
    const collapsed = localpart.toLowerCase().replace(/[._-]/g, "");
    if (AUTOMATED_LOCALPART_MARKERS.some((marker) => collapsed.includes(marker))) return true;
    if (HARD_LOCALPART_EXACT.has(collapsed)) return true;
    if (AUTOMATED_SENDER_DOMAINS.has(domain)) return true;
    // Second-signal class — each decisive on its own, which also covers the
    // "SOFT localpart + second signal" combination (SOFT_LOCALPART_EXACT).
    if (isESPDomain(domain)) return true;
    const labels = domain.split(".");
    if (labels.length >= 3 && AUTOMATED_SUBDOMAIN_LABELS.has(labels[0])) return true;
    // Templated subject from a non-personal domain → transactional template.
    if (subject && !isPersonalMailDomain(domain) && templatedSubject(subject)) return true;
    // A lone SOFT localpart (hello@/team@/events@…) deliberately falls
    // through to "human" — see SOFT_LOCALPART_EXACT.
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

/** A raw Gmail message as `format=full` returns it (loose — read defensively). */
export interface GmailFullMessage {
  id?: string;
  threadId?: string;
  internalDate?: string;
  snippet?: string;
  payload?: GmailPart;
}

/** Wire rows + signals for one raw `format=full` Gmail message. */
export interface NormalizedGmailMessage {
  threadId: string;
  automated: boolean;
  sentAtMs: number;
  contact: WireContact | null;
  thread: WireThread;
  message: WireMessage;
}

/** One raw Gmail message → wire rows + its automated signal. Shared by the
    account-wide sweep and the deep per-thread pass (ingest dedups on
    platform+messageID, so overlap between the two is free). */
export function normalizeGmailMessage(msg: GmailFullMessage, myEmail: string): NormalizedGmailMessage | null {
  const id = msg.id;
  if (!id) return null;
  const headers: GmailHeader[] = msg.payload?.headers ?? [];
  const header = (n: string) => headers.find((h) => h.name.toLowerCase() === n)?.value;
  const from = parseAddress(header("from"));
  const subject = header("subject") ?? null;
  const threadId = String(msg.threadId ?? id);
  const sentAtMs = msg.internalDate ? Number(msg.internalDate) : Date.now();
  const sentAt = new Date(sentAtMs).toISOString();
  const isFromMe = Boolean(from.email && myEmail && from.email === myEmail);

  const { text, html, attachments } = walkParts(msg.payload ?? {});
  const body = (text ?? (html ? stripHtml(html) : null) ?? String(msg.snippet ?? ""))
    .slice(0, BODY_CHAR_CAP);

  return {
    threadId,
    automated: automatedSignals(headers, from.email, subject),
    sentAtMs,
    contact: (!isFromMe && from.email)
      ? { platform: "gmail", handle: from.email, displayName: from.name, isMe: false }
      : null,
    thread: {
      platform: "gmail", platformThreadID: threadId, providerThreadID: threadId,
      title: subject ?? from.name ?? from.email, isGroup: false, lastMessageAt: sentAt,
    },
    message: {
      platform: "gmail", platformMessageID: id, platformThreadID: threadId,
      senderHandle: isFromMe ? null : from.email,
      isFromMe, text: body, sentAt, readAt: null,
      attachments: gmailAttachmentsToWire(attachments),
    },
  };
}

/** GET a Gmail API URL as JSON, waiting out one 429 (Retry-After honoured,
    capped at 30s) so a quota blip mid-import degrades to a pause, not a failure.
    Throws on any other non-200 — parsing an error body as if it were the
    payload would silently import garbage (an empty /profile flips EVERY
    message to isFromMe:false). */
async function gmailGet(url: string, auth: Record<string, string>): Promise<Record<string, unknown>> {
  let res = await fetch(url, { headers: auth });
  if (res.status === 429) {
    const seconds = Number(res.headers.get("retry-after") ?? "1");
    await new Promise((r) => setTimeout(r, Math.min(Math.max(seconds || 1, 1), 30) * 1000));
    res = await fetch(url, { headers: auth });
  }
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`gmail GET → ${res.status}: ${body.slice(0, 200)}`);
  }
  return res.json() as Promise<Record<string, unknown>>;
}

export async function backfillGmail(deviceId: string, connectionId: string, accessToken: string): Promise<void> {
  const store = getStore();
  const auth = { Authorization: `Bearer ${accessToken}` };
  const api = "https://gmail.googleapis.com/gmail/v1/users/me";
  const maxMessages = envInt("OSMO_GMAIL_MAX_MESSAGES", MAX_MESSAGES_DEFAULT);

  try {
    // Who am I (to mark isFromMe)? An empty/missing profile email would make
    // the user their own counterparty on every imported message — abort into
    // the degraded pathway below rather than import garbage.
    const profile = await gmailGet(`${api}/profile`, auth);
    const myEmail = String(profile.emailAddress ?? "").toLowerCase();
    if (!myEmail) throw new Error("gmail profile returned no email address");

    // Page (id, threadId) pairs — messages.list already returns both, so the
    // demo/scope gate runs BEFORE the heavier per-message fetch (quota win
    // over the old fetch-then-gate order).
    const items: { id: string; threadId: string }[] = [];
    let pageToken: string | undefined;
    // Page ceiling: `items` may not grow on every page (messages.list with a
    // q filter legitimately returns EMPTY pages that still carry a
    // nextPageToken), so the while-condition alone can't bound the loop.
    const maxListPages = Math.max(20, Math.ceil(maxMessages / PAGE_SIZE) * 4);
    for (let page_ = 0; page_ < maxListPages && items.length < maxMessages; page_++) {
      const q = new URLSearchParams({ maxResults: String(PAGE_SIZE), q: historyQuery() });
      if (pageToken) q.set("pageToken", pageToken);
      const list = await gmailGet(`${api}/messages?${q}`, auth) as {
        messages?: { id: string; threadId: string }[]; nextPageToken?: string;
      };
      for (const m of list.messages ?? []) {
        items.push({ id: m.id, threadId: m.threadId });
      }
      // No next token, or the SAME token echoed back (a stuck upstream would
      // otherwise re-fetch this page until the ceiling) → done.
      if (!list.nextPageToken || list.nextPageToken === pageToken) break;
      pageToken = list.nextPageToken;
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
    // Most-recent activity per thread — ranks the deep-fetch candidates.
    const lastActivityByThread = new Map<string, number>();

    const collect = (norm: NormalizedGmailMessage) => {
      // The user's OWN messages never feed the sticky flag — someone mailing
      // from hello@their-domain.com (or writing "Invoice for June") would
      // otherwise flag their own active threads and knock them out of the
      // deep-history pass below.
      const automated = norm.automated && !norm.message.isFromMe;
      automatedByThread.set(norm.threadId, (automatedByThread.get(norm.threadId) ?? false) || automated);
      lastActivityByThread.set(norm.threadId, Math.max(lastActivityByThread.get(norm.threadId) ?? 0, norm.sentAtMs));
      if (norm.contact) contacts.set(norm.contact.handle, norm.contact);
      threads.set(norm.threadId, norm.thread);
      messages.push(norm.message);
    };

    for (const item of items) {
      // User hit "Stop": the connection was flipped off "backfilling" — bail and
      // keep whatever we've collected so far (finish() below appends it).
      if (store.connectionById(connectionId)?.status !== "backfilling") break;
      if (!gate(item.threadId)) continue;   // gate BEFORE the format=full fetch

      const msg = await gmailGet(`${api}/messages/${item.id}?format=full`, auth).catch(() => null);
      if (!msg) continue;
      const norm = normalizeGmailMessage(msg as GmailFullMessage, myEmail);
      if (norm) collect(norm);
    }

    // Deep pass: the N most-recently-active NON-automated threads get their
    // whole conversation pulled (one threads.get call each = every message,
    // full context) beyond whatever slice the sweep happened to cover.
    const deep = deepFetchScope();
    const deepIds = [...lastActivityByThread.entries()]
      .filter(([tid]) => automatedByThread.get(tid) !== true)
      .sort((a, b) => b[1] - a[1])
      .slice(0, deep.conversations)
      .map(([tid]) => tid);
    for (const tid of deepIds) {
      if (store.connectionById(connectionId)?.status !== "backfilling") break;
      const thread = await gmailGet(`${api}/threads/${encodeURIComponent(tid)}?format=full`, auth)
        .catch(() => null) as { messages?: GmailFullMessage[] } | null;
      if (!thread?.messages) continue;
      // Newest messagesPerConversation of the thread (Gmail returns oldest-first).
      for (const m of thread.messages.slice(-deep.messagesPerConversation)) {
        const norm = normalizeGmailMessage(m, myEmail);
        if (norm) collect(norm);
      }
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
    if (store.connectionById(connectionId)?.status === "backfilling") {
      store.setConnectionStatus(connectionId, "degraded");
      publish(deviceId, { type: "connection.status", platform: "gmail", status: "degraded", connectionId });
    }
    console.error(`[gmail backfill] failed:`, (err as Error).message);
  }
}

function finish(deviceId: string, connectionId: string) {
  const store = getStore();
  // Terminal flip ONLY from "backfilling": a user pause (or disconnect) that
  // made the import bail must not be overridden back to "connected" here.
  if (store.connectionById(connectionId)?.status === "backfilling") {
    store.touchConnection(connectionId, { lastSyncAt: new Date().toISOString() });
    store.setConnectionStatus(connectionId, "connected", 1);
    publish(deviceId, { type: "connection.status", platform: "gmail", status: "connected", connectionId });
  }
  publish(deviceId, { type: "sync.dirty", seq: store.appendRows(deviceId, {}) });
}
