// In-memory ConnectionsStore — the keyless/demo backing store (palo-outreach
// db.js pattern). Everything lives on globalThis so Next.js dev hot-reload
// doesn't silently reset state mid-session. The interface is the DB seam: a
// Postgres implementation swaps in behind getStore() with no route changes.
//
// Restart amnesia is BY DESIGN in keyless mode: the Mac app handles 401 by
// re-registering and resetting its cursor; deterministic IDs + change-aware
// ingest make the full re-pull idempotent.

import crypto from "node:crypto";
import { getAccounts } from "../accounts/store";
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
  /** PKCE verifier for X OAuth (stored at authorize, read at token exchange). */
  codeVerifier?: string;
}

/** Server-side subscription state per device — the SOURCE OF TRUTH for a
    device's tier (the app only caches a signed copy). Postgres later. */
export interface LicenseRecord {
  deviceId: string;
  licenseKey: string | null;
  subscriptionActive: boolean;
  plan: string | null;            // product/price id when subscribed
  trialStartedAt: number | null;  // epoch ms — server-recorded so it can't be reset client-side
}

/** Rolling weekly usage window for the free-tier quota. */
export interface UsageWindow {
  weekStart: number;              // epoch ms
  count: number;
}

/** A single-use email magic-link token — the web login flow. */
export interface MagicLink {
  token: string;
  email: string;
  expiresAt: number;   // epoch ms
  used: boolean;
}

/** A signed-in browser session (web account page — separate from the Mac
    app's device-token auth). */
export interface WebSession {
  token: string;
  email: string;
  createdAt: number;   // epoch ms
}

export interface ConnectionsStore {
  registerDevice(): Device;
  /** Rehydrate a known (durable) device into the in-memory map after a restart. */
  adoptDevice(id: string, token: string): Device;
  deviceByToken(token: string): Device | null;
  deviceById(id: string): Device | null;

  createPendingLink(deviceId: string, platform: Platform): PendingLink;
  /** Single-use: returns null the second time or for unknown ids. */
  resolvePendingLink(linkId: string): PendingLink | null;
  peekPendingLink(linkId: string): PendingLink | null;

  addConnection(c: Connection): void;
  hydrateConnection(c: Connection): void;
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

  // Subscription / trial — the server-side source of truth for a device's tier.
  license(deviceId: string): LicenseRecord;
  setLicense(deviceId: string, patch: Partial<LicenseRecord>): LicenseRecord;
  /** Start the trial once; idempotent (a second call never re-opens it). */
  startTrial(deviceId: string, nowMs: number): LicenseRecord;

  // Free-tier weekly usage quota (server-enforced so a client can't lie).
  usage(deviceId: string): UsageWindow;
  /** Bump usage for the week containing `weekStartMs`, rolling over on a new week. */
  bumpUsage(deviceId: string, weekStartMs: number): UsageWindow;

  /** Account deletion: purge EVERY server record for a device. */
  purgeDevice(deviceId: string): void;

  // Web login (magic link) — separate from the Mac app's device-token auth.
  /** Mints a fresh 15-minute single-use link for the given email. */
  createMagicLink(email: string, nowMs: number): MagicLink;
  /** Single-use + expiry-checked: returns the email once, then never again. */
  consumeMagicLink(token: string, nowMs: number): string | null;
  createWebSession(email: string): WebSession;
  webSession(token: string): WebSession | null;
  deleteWebSession(token: string): void;
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
  licenses: Map<string, LicenseRecord>;      // deviceId → subscription/trial state
  usage: Map<string, UsageWindow>;           // deviceId → weekly free-tier usage
  magicLinks: Map<string, MagicLink>;        // token → link
  webSessions: Map<string, WebSession>;      // token → session
}

function freshState(): MemoryState {
  return {
    devices: new Map(), links: new Map(), connections: new Map(),
    oplogs: new Map(), dedup: new Map(), seqs: new Map(),
    oauth: new Map(), outboxes: new Map(),
    licenses: new Map(), usage: new Map(),
    magicLinks: new Map(), webSessions: new Map(),
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
  adoptDevice(id: string, token: string): Device {
    const existing = this.s.devices.get(token);
    if (existing) return existing;
    const device: Device = { id, token, createdAt: new Date().toISOString() };
    this.s.devices.set(token, device);
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

  addConnection(c: Connection) {
    this.s.connections.set(c.id, c);
    void getAccounts().upsertConnection(c).catch(() => {}); // durable (fire-and-forget)
  }
  /** Load a connection into memory WITHOUT re-persisting it (used to rehydrate
      from the durable store after a redeploy). */
  hydrateConnection(c: Connection) { this.s.connections.set(c.id, c); }
  connections(deviceId: string) {
    return [...this.s.connections.values()].filter(c => c.deviceId === deviceId);
  }
  connectionById(id: string) { return this.s.connections.get(id) ?? null; }
  setConnectionStatus(id: string, status: ConnectionStatus, progress?: number) {
    const c = this.s.connections.get(id);
    if (!c) return;
    const statusChanged = c.status !== status;
    c.status = status;
    if (progress !== undefined) c.backfillProgress = progress;
    // Persist on status transitions only (not every backfill-progress tick).
    if (statusChanged) void getAccounts().upsertConnection(c).catch(() => {});
  }
  removeConnection(id: string) {
    this.s.connections.delete(id);
    void getAccounts().deleteConnection(id).catch(() => {}); // durable
  }

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

  license(deviceId: string): LicenseRecord {
    return this.s.licenses.get(deviceId) ?? {
      deviceId, licenseKey: null, subscriptionActive: false, plan: null, trialStartedAt: null,
    };
  }
  setLicense(deviceId: string, patch: Partial<LicenseRecord>): LicenseRecord {
    const merged = { ...this.license(deviceId), ...patch, deviceId };
    this.s.licenses.set(deviceId, merged);
    return merged;
  }
  startTrial(deviceId: string, nowMs: number): LicenseRecord {
    const rec = this.license(deviceId);
    if (rec.trialStartedAt != null) return rec;   // idempotent — never re-opens
    return this.setLicense(deviceId, { trialStartedAt: nowMs });
  }

  usage(deviceId: string): UsageWindow {
    return this.s.usage.get(deviceId) ?? { weekStart: 0, count: 0 };
  }
  bumpUsage(deviceId: string, weekStartMs: number): UsageWindow {
    const cur = this.usage(deviceId);
    const next = cur.weekStart === weekStartMs
      ? { weekStart: weekStartMs, count: cur.count + 1 }
      : { weekStart: weekStartMs, count: 1 };
    this.s.usage.set(deviceId, next);
    return next;
  }

  purgeDevice(deviceId: string): void {
    this.s.licenses.delete(deviceId);
    this.s.usage.delete(deviceId);
    this.s.oplogs.delete(deviceId);
    this.s.dedup.delete(deviceId);
    this.s.seqs.delete(deviceId);
    this.s.outboxes.delete(deviceId);
    for (const key of [...this.s.oauth.keys()]) {
      if (key.startsWith(`${deviceId}:`)) this.s.oauth.delete(key);
    }
    for (const [id, c] of [...this.s.connections]) {
      if (c.deviceId === deviceId) this.s.connections.delete(id);
    }
    for (const [token, d] of [...this.s.devices]) {
      if (d.id === deviceId) this.s.devices.delete(token);
    }
  }

  createMagicLink(email: string, nowMs: number): MagicLink {
    const link: MagicLink = {
      token: crypto.randomBytes(24).toString("base64url"),
      email, expiresAt: nowMs + 15 * 60_000, used: false,
    };
    this.s.magicLinks.set(link.token, link);
    return link;
  }
  consumeMagicLink(token: string, nowMs: number): string | null {
    const link = this.s.magicLinks.get(token);
    if (!link || link.used || link.expiresAt < nowMs) return null;
    link.used = true;
    return link.email;
  }
  createWebSession(email: string): WebSession {
    const session: WebSession = { token: crypto.randomBytes(24).toString("base64url"), email, createdAt: Date.now() };
    this.s.webSessions.set(session.token, session);
    return session;
  }
  webSession(token: string): WebSession | null { return this.s.webSessions.get(token) ?? null; }
  deleteWebSession(token: string): void { this.s.webSessions.delete(token); }
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
