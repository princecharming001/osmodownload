// Unipile webhook/API JSON → wire rows. Pure functions, fixture-testable.
// Live-mode only path (mock mode seeds wire rows directly).

import type { Platform, WireContact, WireMessage, WireThread } from "../connections/types";
import type { RowBundle } from "../connections/memoryStore";

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
