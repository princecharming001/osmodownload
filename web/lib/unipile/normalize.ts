// Unipile webhook/API JSON → wire rows. Pure functions, fixture-testable.
// Live-mode only path (mock mode seeds wire rows directly).

import type { Platform, WireContact, WireMessage, WireThread } from "../connections/types";
import type { RowBundle } from "../connections/memoryStore";
import type { UnipileChat, UnipileMessage } from "./client";

/** Read the first present key from a loose object (Unipile field names vary
    a little by provider; we degrade instead of crashing). */
function pick(obj: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) if (obj[k] != null) return obj[k];
  return undefined;
}

/** chatId → {title, isGroup} from a page of Unipile chats. */
export function chatIndex(chats: UnipileChat[]): Map<string, { title: string | null; isGroup: boolean }> {
  const map = new Map<string, { title: string | null; isGroup: boolean }>();
  for (const c of chats) {
    const id = pick(c, "id", "chat_id", "provider_id") as string | undefined;
    if (!id) continue;
    const title = (pick(c, "name", "subject", "chat_name") as string | undefined) ?? null;
    // Unipile chat `type`: 0/1 direct, 2 group (varies) — treat a present
    // attendee count > 2 or an explicit flag as group.
    const isGroup = Boolean(pick(c, "is_group") ?? (Number(pick(c, "type") ?? 0) >= 2));
    map.set(id, { title, isGroup });
  }
  return map;
}

/** One Unipile message (from GET /messages) → wire rows. */
export function normalizeUnipileMessage(
  msg: UnipileMessage, platform: Platform,
  chats: Map<string, { title: string | null; isGroup: boolean }>,
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

  const contacts: WireContact[] = (!isFromMe && senderHandle) ? [{
    platform, handle: senderHandle, displayName: senderName ?? chat?.title ?? null,
    avatarUrl: senderAvatar ?? null, isMe: false,
  }] : [];
  const threads: WireThread[] = [{
    platform, platformThreadID: chatId,
    title: chat?.title ?? senderName ?? null,
    isGroup: chat?.isGroup ?? false,
    lastMessageAt: sentAt,
  }];
  const messages: WireMessage[] = [{
    platform, platformMessageID: messageId, platformThreadID: chatId,
    senderHandle: isFromMe ? null : (senderHandle ?? null),
    isFromMe, text, sentAt, readAt: null,
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
  }];
  return { contacts, threads, messages };
}
