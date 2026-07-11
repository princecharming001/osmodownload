// Unipile webhook/API JSON → wire rows. Pure functions, fixture-testable.
// Live-mode only path (mock mode seeds wire rows directly).

import type { Platform, WireAttachment, WireContact, WireMessage, WireReaction, WireThread } from "../connections/types";
import type { RowBundle } from "../connections/memoryStore";
import { kindFromMime } from "../connections/attachments";
import type { UnipileChat, UnipileMessage } from "./client";

/** Attachments off a Unipile message, across payload variants (`attachments`
    or `files` arrays; id|attachment_id|provider_id; mimetype|mime_type;
    file_size|size). `post`/`link`-typed entries (shared posts, IG reels) map
    to kind "link" with the destination `url` and a `title`, since there are no
    bytes to fetch. */
/** First http(s) URL anywhere in a payload subtree — canonical keys first,
    then a bounded deep scan. Instagram/LinkedIn share payloads vary too much
    to enumerate (permalink vs share_url vs nested story objects); a real link
    the user can OPEN beats a null every time. */
export function firstHTTPURL(value: unknown, depth = 0): string | null {
  if (depth > 4 || value == null) return null;
  if (typeof value === "string") {
    const m = value.match(/https?:\/\/[^\s"'<>)\]]+/);
    return m ? m[0] : null;
  }
  if (Array.isArray(value)) {
    for (const v of value) { const u = firstHTTPURL(v, depth + 1); if (u) return u; }
    return null;
  }
  if (typeof value === "object") {
    const o = value as Record<string, unknown>;
    for (const k of ["permalink", "share_url", "external_url", "expanded_url", "link", "url", "href"]) {
      const v = o[k];
      if (typeof v === "string" && v.startsWith("http")) return v;
    }
    for (const v of Object.values(o)) { const u = firstHTTPURL(v, depth + 1); if (u) return u; }
  }
  return null;
}

function shareTitle(a: Record<string, unknown>): string | null {
  for (const k of ["title", "name", "caption", "text", "description", "story_title"]) {
    const v = a[k];
    if (typeof v === "string" && v.trim()) return v.trim().slice(0, 120);
  }
  return null;
}

export function readAttachments(msg: Record<string, unknown>): WireAttachment[] | undefined {
  const raw = (msg.attachments ?? msg.files) as unknown;
  const out: WireAttachment[] = [];
  if (Array.isArray(raw)) {
    for (const a of raw as Record<string, unknown>[]) {
      const id = (a.id ?? a.attachment_id ?? a.provider_id) as string | undefined;
      if (!id) continue;
      const mime = (a.mimetype ?? a.mime_type) as string | undefined;
      const kind = kindFromMime(a.type as string | undefined, mime);
      const size = (a.file_size ?? a.size) as unknown;
      out.push({
        id: String(id), kind,
        mimeType: mime ?? null,
        filename: ((a.file_name ?? a.filename) as string | undefined) ?? null,
        sizeBytes: typeof size === "number" ? size : null,
        remoteRef: kind === "link" ? null : String(id),
        url: kind === "link" ? firstHTTPURL(a) : null,
        title: shareTitle(a),
      });
    }
  }
  // A share with NO attachments array and NO text used to become an invisible
  // message (49 of them in one real store). Synthesize a link attachment from
  // any URL the payload carries so the bubble always shows SOMETHING.
  const text = (msg.text ?? msg.body ?? "") as string;
  if (out.length === 0 && (!text || !String(text).trim())) {
    const url = firstHTTPURL({ ...msg, text: undefined, sender: undefined, reactions: undefined });
    if (url) {
      const mid = (msg.id ?? msg.provider_id ?? "share") as string;
      out.push({
        id: `${mid}-share`, kind: "link", mimeType: null, filename: null,
        sizeBytes: null, remoteRef: null, url, title: shareTitle(msg),
      });
    }
  }
  return out.length > 0 ? out : undefined;
}

/** Emoji reactions off a Unipile message, across payload variants
    (`reactions: [{value|emoji|reaction, sender_id|attendee_id, is_sender}]`). */
function readReactions(msg: Record<string, unknown>): WireReaction[] | undefined {
  const raw = msg.reactions;
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const out: WireReaction[] = [];
  for (const r of raw as Record<string, unknown>[]) {
    const emoji = (r.value ?? r.emoji ?? r.reaction) as string | undefined;
    if (!emoji) continue;
    out.push({
      emoji: String(emoji),
      senderHandle: (r.sender_id ?? r.attendee_id ?? r.attendee_provider_id ?? null) as string | null,
      isFromMe: Boolean(r.is_sender ?? r.from_me ?? false),
    });
  }
  return out.length > 0 ? out : undefined;
}

/** The platform id of the message this one quotes/replies to, if any. */
function readReplyTo(msg: Record<string, unknown>): string | null {
  const direct = msg.quoted_message_id ?? msg.replied_message_id ?? msg.reply_to_message_id;
  if (typeof direct === "string" && direct) return direct;
  const nested = (msg.quoted ?? msg.reply_to ?? msg.replied_to) as Record<string, unknown> | undefined;
  const id = nested?.id ?? nested?.message_id ?? nested?.provider_id;
  return typeof id === "string" && id ? id : null;
}

/** Read the first present key from a loose object (Unipile field names vary
    a little by provider; we degrade instead of crashing). */
function pick(obj: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) if (obj[k] != null) return obj[k];
  return undefined;
}

/** chatId → {title, isGroup, providerId} from a page of Unipile chats.
    `providerId` is the provider's OWN thread id (distinct from `id`, Unipile's
    internal chat id) — what a working deep link into the real conversation
    actually needs. */
export function chatIndex(
  chats: UnipileChat[],
): Map<string, { title: string | null; isGroup: boolean; providerId: string | null }> {
  const map = new Map<string, { title: string | null; isGroup: boolean; providerId: string | null }>();
  for (const c of chats) {
    const id = pick(c, "id", "chat_id", "provider_id") as string | undefined;
    if (!id) continue;
    const title = (pick(c, "name", "subject", "chat_name") as string | undefined) ?? null;
    // Unipile chat `type`: 0/1 direct, 2 group (varies) — treat a present
    // attendee count > 2 or an explicit flag as group.
    const isGroup = Boolean(pick(c, "is_group") ?? (Number(pick(c, "type") ?? 0) >= 2));
    const providerId = (c.provider_id as string | undefined) ?? null;
    map.set(id, { title, isGroup, providerId });
  }
  return map;
}

/** One Unipile message (from GET /messages) → wire rows. */
export function normalizeUnipileMessage(
  msg: UnipileMessage, platform: Platform,
  chats: Map<string, { title: string | null; isGroup: boolean; providerId: string | null }>,
): RowBundle | null {
  const chatId = pick(msg, "chat_id", "thread_id", "chat_provider_id") as string | undefined;
  const messageId = pick(msg, "id", "message_id", "provider_id") as string | undefined;
  if (!chatId || !messageId) return null;

  const isFromMe = Boolean(pick(msg, "is_sender", "from_me") ?? false);
  const text = String(pick(msg, "text", "message", "body") ?? "");
  const sentAt = String(pick(msg, "timestamp", "date", "created_at") ?? new Date().toISOString());
  const senderHandle = pick(msg, "sender_attendee_id", "sender_id", "attendee_provider_id", "from") as string | undefined;
  const senderName = pick(msg, "sender_name", "attendee_name") as string | undefined;
  const senderAvatar = pick(msg, "sender_profile_picture", "sender_attendee_picture",
                            "profile_picture", "attendee_picture_url", "picture_url") as string | undefined;
  const chat = chats.get(chatId);

  // The chat-title fallback is only valid in a 1:1 (there the chat's title IS
  // the counterpart's name). In a GROUP, the chat's title is the group's name
  // — falling back to it here was the root cause of the group sender
  // attribution bug (WhatsApp/IG often omit sender_name on group messages, so
  // every sender's displayName silently became the group's title instead of
  // their own name). The backfill's attendee-enrichment pass fills in the
  // real per-attendee name when this leaves displayName null.
  const senderFallbackName = chat?.isGroup ? null : chat?.title ?? null;
  const contacts: WireContact[] = (!isFromMe && senderHandle) ? [{
    platform, handle: senderHandle, displayName: senderName ?? senderFallbackName,
    avatarUrl: senderAvatar ?? null, isMe: false,
  }] : [];
  const threads: WireThread[] = [{
    platform, platformThreadID: chatId,
    title: chat?.title ?? senderName ?? null,
    isGroup: chat?.isGroup ?? false,
    lastMessageAt: sentAt,
    providerThreadID: chat?.providerId ?? null,
  }];
  // Instagram (and some WhatsApp exports) deliver likes as STANDALONE
  // messages ("Liked a message") instead of reaction records. When the
  // target is known, fold it into a real reaction on that message; a full
  // bubble for a like reads as spam. Unfoldable echoes still ship as
  // messages — the client renders them as a system line, not a bubble.
  const echo = /^(liked|loved|laughed at|emphasized|disliked|reacted to) a message$/i.test(text.trim());
  const replyTo = readReplyTo(msg);
  if (echo && replyTo) {
    const messages: WireMessage[] = [{
      platform, platformMessageID: replyTo, platformThreadID: chatId,
      senderHandle: null, isFromMe: false, text: "", sentAt, readAt: null,
      // Patch-style row: dedup by deterministic id merges this reaction onto
      // the existing target message row.
      reactions: [{ emoji: "❤️", senderHandle: isFromMe ? null : (senderHandle ?? null), isFromMe }],
      replyToMessageID: null, attachments: undefined,
    }];
    return { contacts, threads, messages };
  }
  const messages: WireMessage[] = [{
    platform, platformMessageID: messageId, platformThreadID: chatId,
    senderHandle: isFromMe ? null : (senderHandle ?? null),
    isFromMe, text, sentAt, readAt: null,
    reactions: readReactions(msg),
    replyToMessageID: readReplyTo(msg),
    attachments: readAttachments(msg),
  }];
  return { contacts, threads, messages };
}

const PLATFORM_BY_PROVIDER: Record<string, Platform> = {
  LINKEDIN: "linkedin",
  WHATSAPP: "whatsapp",
  INSTAGRAM: "instagram",
  TWITTER: "x",
  // MESSENGER/TELEGRAM: additive later, alongside the Swift Platform enum.
};

export function platformForProvider(provider: string | undefined): Platform | null {
  if (!provider) return null;
  return PLATFORM_BY_PROVIDER[provider.toUpperCase()] ?? null;
}

/** Normalize a Unipile `message_received` webhook payload. Unknown/missing
    fields degrade to null rather than throwing — webhooks must always 200. */
export function normalizeMessageWebhook(payload: Record<string, unknown>): RowBundle | null {
  const provider = (payload.account_type ?? payload.provider) as string | undefined;
  const platform = platformForProvider(provider);
  const chatId = (payload.chat_id ?? payload.thread_id) as string | undefined;
  const messageId = (payload.message_id ?? payload.id) as string | undefined;
  if (!platform || !chatId || !messageId) return null;

  const sender = payload.sender as Record<string, unknown> | undefined;
  const senderHandle = (sender?.attendee_provider_id ?? sender?.id) as string | undefined;
  const senderName = (sender?.attendee_name ?? sender?.name) as string | undefined;
  const isFromMe = Boolean(payload.is_sender ?? payload.from_me ?? false);
  const text = String(payload.message ?? payload.text ?? "");
  const sentAt = String(payload.timestamp ?? new Date().toISOString());

  const contacts: WireContact[] = senderHandle && !isFromMe ? [{
    platform, handle: senderHandle, displayName: senderName ?? null, isMe: false,
  }] : [];
  const threads: WireThread[] = [{
    platform, platformThreadID: chatId,
    title: (payload.chat_name as string | undefined) ?? senderName ?? null,
    isGroup: Boolean(payload.is_group ?? false),
    lastMessageAt: sentAt,
  }];
  const messages: WireMessage[] = [{
    platform, platformMessageID: messageId, platformThreadID: chatId,
    senderHandle: isFromMe ? null : senderHandle ?? null,
    isFromMe, text, sentAt, readAt: null,
    reactions: readReactions(payload),
    replyToMessageID: readReplyTo(payload),
    attachments: readAttachments(payload),
  }];
  return { contacts, threads, messages };
}
