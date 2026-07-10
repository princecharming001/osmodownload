// The Osmo wire contract — the single source of truth for every JSON shape the
// Mac app and this backend exchange. The backend speaks PLATFORM-NATIVE IDs
// (platformMessageID / platformThreadID / handle); the Mac mints deterministic
// UUIDs from them. Never send Osmo UUIDs over this wire.

export type Platform =
  | "imessage"   // never actually served by the backend (local-only on the Mac)
  | "gmail"
  | "slack"
  | "whatsapp"
  | "linkedin"
  | "x"
  | "instagram";

/** Platforms a user can connect through the backend (iMessage is local). */
export const CONNECTABLE: Platform[] = [
  "linkedin", "whatsapp", "instagram", "gmail", "slack", "x",
];

// ---------------------------------------------------------------------------
// Normalized rows (what /api/sync/pull returns)

export interface WireContact {
  platform: Platform;
  handle: string;            // platform-native identity (phone, email, urn, id)
  displayName: string | null;
  avatarUrl?: string | null; // profile picture URL; the app fetches + caches it
  isMe: boolean;
}

export interface WireThread {
  platform: Platform;
  platformThreadID: string;
  title: string | null;
  isGroup: boolean;
  lastMessageAt: string | null;  // ISO-8601
  /** Server-side automated-sender signal (List-Unsubscribe / Precedence:bulk /
      List-Id / no-reply sender) — feeds the human-thread classifier. */
  automatedHint?: boolean;
  /** The provider's OWN thread/conversation id (not Unipile's internal chat id) —
      what a deep link into LinkedIn/Instagram/WhatsApp/Slack actually needs. */
  providerThreadID?: string | null;
}

export interface WireReaction {
  emoji: string;
  senderHandle: string | null;   // null when unknown
  isFromMe: boolean;
}

export type AttachmentKind = "image" | "video" | "audio" | "file" | "link";

export interface WireAttachment {
  /** Stable per-attachment key (dedup) — provider attachment/file id. */
  id: string;
  kind: AttachmentKind;
  mimeType: string | null;
  filename: string | null;
  sizeBytes: number | null;
  width?: number | null;
  height?: number | null;
  /** Opaque ref used to refetch bytes through /api/media — provider-specific
      (Gmail attachmentId, Slack url_private, Unipile attachment id). Absent
      for `link` kind, which has no bytes to fetch. */
  remoteRef?: string | null;
  /** Destination URL for `link` kind (a shared post/reel) — no bytes exist. */
  url?: string | null;
  title?: string | null;
}

export interface WireMessage {
  platform: Platform;
  platformMessageID: string;
  platformThreadID: string;
  senderHandle: string | null;
  isFromMe: boolean;
  text: string;
  sentAt: string;                // ISO-8601
  readAt: string | null;
  /** Emoji reactions on this message, when the provider exposes them. */
  reactions?: WireReaction[];
  /** The platform message id this one replies to (quoted/threaded reply). */
  replyToMessageID?: string | null;
  /** Media/files/shared-post attachments, when the provider exposes them. */
  attachments?: WireAttachment[];
}

export interface WireBatch {
  contacts: WireContact[];
  threads: WireThread[];
  messages: WireMessage[];
  cursor: string;                // opaque; max oplog seq included in this page
  hasMore: boolean;
  /** Identity of this oplog sequence space (new per server boot). A client
      holding a cursor minted under a different epoch must reset to 0 — its
      cursor may be far past this stream's seq and would otherwise silently
      starve it of messages forever (the redeploy-stall bug). */
  epoch?: string;
  /** The device's current max seq — lets a client detect an impossible
      cursor (cursor > maxSeq) even without an epoch change. */
  maxSeq?: number;
}

// ---------------------------------------------------------------------------
// Devices + connections

export interface Device {
  id: string;
  token: string;
  createdAt: string;
}

export type ConnectionStatus =
  | "linking"        // hosted-auth started, waiting on the wizard
  | "backfilling"    // history import in progress
  | "connected"      // live
  | "degraded"       // provider session dropped — needs reconnect
  | "paused"         // user paused sync
  | "disconnected";

export interface Connection {
  id: string;                    // our id (mock: "conn-<n>", live: unipile account_id)
  deviceId: string;
  platform: Platform;
  status: ConnectionStatus;
  displayName: string;           // e.g. the account's own name/number
  backfillProgress: number;      // 0..1
  createdAt: string;
  /** Last time rows for this connection were appended (webhook/backfill). ISO-8601. */
  lastSyncAt?: string | null;
  /** Last upstream liveness check (GET /api/accounts?verify=1). ISO-8601. */
  lastVerifiedAt?: string | null;
}

// ---------------------------------------------------------------------------
// Oplog (the pull cursor's substrate)

export type OplogKind = "contact" | "thread" | "message";

export interface OplogEntry {
  seq: number;
  kind: OplogKind;
  row: WireContact | WireThread | WireMessage;
}

// ---------------------------------------------------------------------------
// SSE events — doorbells only, never message bodies. On sync.dirty the app
// runs the same cursor pull it runs on its reconciliation timer.

export type OsmoEvent =
  | { type: "sync.dirty"; seq: number }
  | { type: "connection.status"; platform: Platform; status: ConnectionStatus; connectionId: string }
  | { type: "backfill.progress"; platform: Platform; progress: number };

// ---------------------------------------------------------------------------
// Route payloads

export interface RegisterResponse { deviceId: string; deviceToken: string; mode: "mock" | "live" }
export interface ConnectLinkResponse { url: string; linkId: string; mode: "mock" | "unipile" | "oauth" }
export interface AccountsResponse { connections: Omit<Connection, "deviceId">[] }
export interface SendRequest { platform: Platform; platformThreadID: string; text: string; idempotencyKey?: string }
export interface SendResponse { message: WireMessage }
