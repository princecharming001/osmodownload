// The Unipile seam. Real client when UNIPILE_DSN + UNIPILE_API_KEY are set;
// MockUnipile otherwise (keyless demo mode — the default). Routes never know
// which one they're talking to.

import type { Platform } from "../connections/types";
import { mockUnipile } from "./mock";
import { realUnipile } from "./real";

export interface HostedAuthOptions {
  linkId: string;
  platform: Platform;
  deviceId: string;
  /** Absolute origin of this deployment, e.g. http://localhost:3000 */
  origin: string;
  reconnectAccountId?: string;
}

export interface UnipileAccount {
  id: string;
  /** Live payloads use `type` ("WHATSAPP"…); older docs said `provider`. Read both. */
  provider?: string;
  type?: string;
  name: string;
  /** Top-level on some payloads… */
  status?: "OK" | "CREDENTIALS" | "CONNECTING" | string;
  /** …but live payloads report per-source status here. */
  sources?: { status?: string }[];
}

/** One chat participant, read defensively across providers. */
export interface UnipileAttendee {
  /** Every id a message might reference this sender by (Unipile attendee id,
      provider id…) — index them all or LinkedIn names miss half the time. */
  ids: string[];
  name: string | null;
  pictureUrl: string | null;
  isSelf: boolean;
}

/** A LinkedIn user's public profile, normalized (person-enrichment feature). */
export interface UnipileUserProfile {
  name: string;
  headline: string;
  company: string;
  title: string;
  location: string;
  summary: string;
  positions: { title: string; company: string; period: string | null }[];
  education: { school: string; degree: string | null; period: string | null }[];
  linkedinURL: string | null;
}

/** Health across the payload variants: top-level status or every source OK. */
export function accountIsHealthy(a: UnipileAccount): boolean {
  if (a.status) return a.status === "OK";
  if (a.sources?.length) return a.sources.every((s) => s.status === "OK");
  return false;
}

/** A raw Unipile chat + message, kept loose — the normalizer reads defensively
    across field-name variants so a provider tweak degrades, never crashes. */
export type UnipileChat = Record<string, unknown>;
export type UnipileMessage = Record<string, unknown>;

/** One registered Unipile webhook. */
export interface UnipileWebhook {
  id: string;
  name: string;
  source: string;
  requestUrl: string;
}

export interface UnipileClient {
  readonly mode: "mock" | "live";
  createHostedAuthLink(opts: HostedAuthOptions): Promise<{ url: string }>;
  listAccounts(): Promise<UnipileAccount[]>;
  /** One page of the account's chats (for titles + group flags). */
  listChats(accountId: string, cursor?: string): Promise<{ chats: UnipileChat[]; cursor: string | null }>;
  /** A chat's attendees — the only reliable source of NAMES + avatars on
      LinkedIn/Instagram, where message payloads carry raw attendee ids. */
  listChatAttendees(chatId: string): Promise<UnipileAttendee[]>;
  /** Full public profile for a LinkedIn user. `identifier` is the attendee /
      provider id our contacts already carry. null = not found (stale handle) —
      a degradation, never an error. */
  getUserProfile(accountId: string, identifier: string): Promise<UnipileUserProfile | null>;
  /** One page of the account's messages across all chats (newest first).
      `sinceISO` asks the provider for messages on/after that instant (deep backfill). */
  listMessages(accountId: string, cursor?: string, sinceISO?: string): Promise<{ messages: UnipileMessage[]; cursor: string | null }>;
  /** One page of a SINGLE chat's messages (deep per-conversation fetch). */
  listChatMessages(chatId: string, cursor?: string): Promise<{ messages: UnipileMessage[]; cursor: string | null }>;
  /** Send into a chat; resolves with the provider's real message id. */
  sendMessage(accountId: string, chatId: string, text: string): Promise<{ messageId: string }>;
  /** Raw bytes of one message's attachment — null when not found or no live
      key (the media route falls back to a placeholder in that case). */
  downloadAttachment(accountId: string, messageId: string, attachmentId: string): Promise<Buffer | null>;

  // Webhook registration — present only on the live client. Tenant-wide key,
  // so callers must only ever touch hooks THEY created (matched by name) and
  // never enumerate-and-wipe.
  listWebhooks?(): Promise<UnipileWebhook[]>;
  createWebhook?(opts: { name: string; source: string; requestUrl: string }): Promise<UnipileWebhook>;
  deleteWebhook?(id: string): Promise<void>;
}

export function isLiveUnipile(): boolean {
  return Boolean(process.env.UNIPILE_DSN && process.env.UNIPILE_API_KEY);
}

export function getUnipile(): UnipileClient {
  return isLiveUnipile() ? realUnipile() : mockUnipile();
}
