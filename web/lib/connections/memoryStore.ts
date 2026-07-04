// In-memory ConnectionsStore — the keyless/demo backing store (palo-outreach
// db.js pattern). Everything lives on globalThis so Next.js dev hot-reload
// doesn't silently reset state mid-session. The interface is the DB seam: a
// Postgres implementation swaps in behind getStore() with no route changes.
//
// Restart amnesia is BY DESIGN in keyless mode: the Mac app handles 401 by
// re-registering and resetting its cursor; deterministic IDs + change-aware
// ingest make the full re-pull idempotent.

import crypto from "node:crypto";
import type {
  Connection, ConnectionStatus, Device, OplogEntry, OplogKind, Platform,
  WireBatch, WireContact, WireMessage, WireThread,
} from "./types";

export interface RowBundle {
  contacts?: WireContact[];
  threads?: WireThread[];
  messages?: WireMessage[];
}

export interface PendingLink {
  linkId: string;
  deviceId: string;
  platform: Platform;
  createdAt: number;
  used: boolean;
}

export interface ConnectionsStore {
  registerDevice(): Device;
  deviceByToken(token: string): Device | null;
  deviceById(id: string): Device | null;

  createPendingLink(deviceId: string, platform: Platform): PendingLink;
  /** Single-use: returns null the second time or for unknown ids. */
  resolvePendingLink(linkId: string): PendingLink | null;
  peekPendingLink(linkId: string): PendingLink | null;

  addConnection(c: Connection): void;
  connections(deviceId: string): Connection[];
  connectionById(id: string): Connection | null;
  setConnectionStatus(id: string, status: ConnectionStatus, progress?: number): void;
  removeConnection(id: string): void;

  /** Append normalized rows to the device oplog. Dedups: an identical row is a
      no-op; a CHANGED row (same native key, different content) appends a fresh
      entry so cursors pick the update up. Returns the new max seq (0 if none). */
  appendRows(deviceId: string, rows: RowBundle): number;
  pull(deviceId: string, since: number, limit: number): WireBatch;
  maxSeq(deviceId: string): number;

  // Server-held provider tokens (Gmail/Slack OAuth) — never sent to the app.
  setOAuthTokens(deviceId: string, platform: Platform, tokens: unknown): void;
  oauthTokens(deviceId: string, platform: Platform): unknown | null;

  // Mock outbox — what /api/sync/send recorded (E2E assertion surface).
  recordOutbound(deviceId: string, message: WireMessage): void;
  outbox(deviceId: string): WireMessage[];
}

interface MemoryState {
  devices: Map<string, Device>;              // token → Device
  links: Map<string, PendingLink>;           // linkId → link
  connections: Map<string, Connection>;      // id → Connection
  oplogs: Map<string, OplogEntry[]>;         // deviceId → entries
  dedup: Map<string, Map<string, string>>;   // deviceId → (dedupKey → contentHash)
  seqs: Map<string, number>;                 // deviceId → last seq
  oauth: Map<string, unknown>;               // `${deviceId}:${platform}` → tokens
  outboxes: Map<string, WireMessage[]>;      // deviceId → sent messages
}

function freshState(): MemoryState {
  return {
    devices: new Map(), links: new Map(), connections: new Map(),
    oplogs: new Map(), dedup: new Map(), seqs: new Map(),
    oauth: new Map(), outboxes: new Map(),
  };
}

function hash(v: unknown): string {
  return crypto.createHash("sha1").update(JSON.stringify(v)).digest("hex");
}

function nativeKey(kind: OplogKind, row: WireContact | WireThread | WireMessage): string {
  switch (kind) {
    case "contact": { const c = row as WireContact; return `contact:${c.platform}:${c.handle}`; }
    case "thread":  { const t = row as WireThread;  return `thread:${t.platform}:${t.platformThreadID}`; }
    case "message": { const m = row as WireMessage; return `message:${m.platform}:${m.platformMessageID}`; }
  }
}

class MemoryConnectionsStore implements ConnectionsStore {
  private s: MemoryState;
  constructor(state: MemoryState) { this.s = state; }

  registerDevice(): Device {
    const device: Device = {
      id: `dev-${crypto.randomUUID()}`,
      token: crypto.randomBytes(24).toString("base64url"),
      createdAt: new Date().toISOString(),
    };
    this.s.devices.set(device.token, device);
    return device;
  }
  deviceByToken(token: string) { return this.s.devices.get(token) ?? null; }
  deviceById(id: string) {
    for (const d of this.s.devices.values()) if (d.id === id) return d;
    return null;
  }

  createPendingLink(deviceId: string, platform: Platform): PendingLink {
    const link: PendingLink = {
      linkId: `link-${crypto.randomUUID()}`,
      deviceId, platform, createdAt: Date.now(), used: false,
    };
    this.s.links.set(link.linkId, link);
    return link;
  }
  resolvePendingLink(linkId: string): PendingLink | null {
    const link = this.s.links.get(linkId);
    if (!link || link.used) return null;
    link.used = true;
    return link;
  }
  peekPendingLink(linkId: string): PendingLink | null {
    return this.s.links.get(linkId) ?? null;
  }

  addConnection(c: Connection) { this.s.connections.set(c.id, c); }
  connections(deviceId: string) {
    return [...this.s.connections.values()].filter(c => c.deviceId === deviceId);
  }
  connectionById(id: string) { return this.s.connections.get(id) ?? null; }
  setConnectionStatus(id: string, status: ConnectionStatus, progress?: number) {
    const c = this.s.connections.get(id);
    if (!c) return;
    c.status = status;
    if (progress !== undefined) c.backfillProgress = progress;
  }
  removeConnection(id: string) { this.s.connections.delete(id); }

  appendRows(deviceId: string, rows: RowBundle): number {
    const oplog = this.s.oplogs.get(deviceId) ?? [];
    const dedup = this.s.dedup.get(deviceId) ?? new Map<string, string>();
    let seq = this.s.seqs.get(deviceId) ?? 0;

    const push = (kind: OplogKind, row: WireContact | WireThread | WireMessage) => {
      const key = nativeKey(kind, row);
      const h = hash(row);
      if (dedup.get(key) === h) return;   // identical → no-op, no seq burn
      dedup.set(key, h);
      seq += 1;
      oplog.push({ seq, kind, row });
    };

    // FK-safe order: contacts → threads → messages.
    for (const c of rows.contacts ?? []) push("contact", c);
    for (const t of rows.threads ?? []) push("thread", t);
    for (const m of rows.messages ?? []) push("message", m);

    this.s.oplogs.set(deviceId, oplog);
    this.s.dedup.set(deviceId, dedup);
    this.s.seqs.set(deviceId, seq);
    return seq;
  }

  pull(deviceId: string, since: number, limit: number): WireBatch {
    const oplog = this.s.oplogs.get(deviceId) ?? [];
    const page = oplog.filter(e => e.seq > since).slice(0, limit);
    const batch: WireBatch = {
      contacts: [], threads: [], messages: [],
      cursor: String(page.length ? page[page.length - 1].seq : since),
      hasMore: false,
    };
    for (const e of page) {
      if (e.kind === "contact") batch.contacts.push(e.row as WireContact);
      else if (e.kind === "thread") batch.threads.push(e.row as WireThread);
      else batch.messages.push(e.row as WireMessage);
    }
    const last = page.length ? page[page.length - 1].seq : since;
    batch.hasMore = oplog.some(e => e.seq > last);
    return batch;
  }
  maxSeq(deviceId: string) { return this.s.seqs.get(deviceId) ?? 0; }

  setOAuthTokens(deviceId: string, platform: Platform, tokens: unknown) {
    this.s.oauth.set(`${deviceId}:${platform}`, tokens);
  }
  oauthTokens(deviceId: string, platform: Platform) {
    return this.s.oauth.get(`${deviceId}:${platform}`) ?? null;
  }

  recordOutbound(deviceId: string, message: WireMessage) {
    const box = this.s.outboxes.get(deviceId) ?? [];
    box.push(message);
    this.s.outboxes.set(deviceId, box);
  }
  outbox(deviceId: string) { return this.s.outboxes.get(deviceId) ?? []; }
}

// globalThis singleton — survives route-module re-evaluation in `next dev`.
const g = globalThis as unknown as { __osmoConnStore?: MemoryConnectionsStore };

export function getStore(): ConnectionsStore {
  g.__osmoConnStore ??= new MemoryConnectionsStore(freshState());
  return g.__osmoConnStore;
}

/** Test-only: wipe all state (fresh store per test). */
export function resetStoreForTests(): void {
  g.__osmoConnStore = new MemoryConnectionsStore(freshState());
}
