// MockUnipile — the keyless stand-in that makes the ENTIRE connect→backfill→
// realtime→send loop run with zero env vars. Hosted-auth links point at our
// local /connect/mock wizard; "authorizing" instantly seeds deterministic demo
// conversations; a drip timer then emits scripted inbound messages so realtime
// SSE is demonstrable and testable.

import crypto from "node:crypto";
import type { Connection, Platform } from "../connections/types";
import { getStore } from "../connections/memoryStore";
import { publish } from "../connections/events";
import { demoAccountName, demoConversations, dripMessage } from "../demo/seed";
import type { HostedAuthOptions, UnipileAccount, UnipileClient } from "./client";

const DRIP_DEFAULT_MS = 20_000;

const g = globalThis as unknown as {
  __osmoDrips?: Map<string, { timer: ReturnType<typeof setInterval>; count: number }>;
};

function drips() {
  g.__osmoDrips ??= new Map();
  return g.__osmoDrips;
}

/** Called by /api/connect/mock/complete — the mock wizard's "Authorize". */
export function completeMockConnect(deviceId: string, platform: Platform): Connection {
  const store = getStore();
  const connection: Connection = {
    id: `conn-${crypto.randomUUID().slice(0, 8)}`,
    deviceId,
    platform,
    status: "backfilling",
    displayName: demoAccountName(platform),
    backfillProgress: 0,
    createdAt: new Date().toISOString(),
  };
  store.addConnection(connection);
  publish(deviceId, { type: "connection.status", platform, status: "backfilling", connectionId: connection.id });

  // Mock backfill = synchronous seed + one progress arc.
  const seq = store.appendRows(deviceId, demoConversations(platform));
  publish(deviceId, { type: "backfill.progress", platform, progress: 1 });
  store.setConnectionStatus(connection.id, "connected", 1);
  publish(deviceId, { type: "connection.status", platform, status: "connected", connectionId: connection.id });
  if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });

  startDrip(deviceId, connection.id, platform);
  return { ...connection, status: "connected", backfillProgress: 1 };
}

/** Scripted inbound every ~20s (OSMO_MOCK_DRIP_MS overridable; 0 disables). */
export function startDrip(deviceId: string, connectionId: string, platform: Platform): void {
  const ms = Number(process.env.OSMO_MOCK_DRIP_MS ?? DRIP_DEFAULT_MS);
  if (!ms || Number.isNaN(ms)) return;
  const key = connectionId;
  if (drips().has(key)) return;   // hot-reload / double-connect guard

  const entry = { timer: setInterval(() => {
    const store = getStore();
    const conn = store.connectionById(connectionId);
    if (!conn || conn.status === "paused" || conn.status === "disconnected") return;
    const bundle = dripMessage(platform, entry.count);
    if (!bundle) return;
    entry.count += 1;
    const seq = store.appendRows(deviceId, bundle);
    if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
  }, ms), count: 0 };
  // Don't hold the process open for the drip timer (dev server exit hygiene).
  entry.timer.unref?.();
  drips().set(key, entry);
}

export function stopDrip(connectionId: string): void {
  const entry = drips().get(connectionId);
  if (entry) { clearInterval(entry.timer); drips().delete(connectionId); }
}

/** Immediate scripted (or custom) inbound — the deterministic E2E trigger. */
export function emitNow(deviceId: string, platform: Platform, text?: string): number {
  const store = getStore();
  const n = Date.now() % 100_000; // unique-enough drip index for dev emits
  const bundle = dripMessage(platform, n, text);
  if (!bundle) return 0;
  const seq = store.appendRows(deviceId, bundle);
  if (seq > 0) publish(deviceId, { type: "sync.dirty", seq });
  return seq;
}

class MockUnipileClient implements UnipileClient {
  readonly mode = "mock" as const;

  async createHostedAuthLink(opts: HostedAuthOptions): Promise<{ url: string }> {
    const url = new URL("/connect/mock", opts.origin);
    url.searchParams.set("linkId", opts.linkId);
    url.searchParams.set("platform", opts.platform);
    return { url: url.toString() };
  }

  async listAccounts(): Promise<UnipileAccount[]> {
    // The mock's account state lives in our store as Connections; routes read
    // those directly, so this is only used by reconciliation in live mode.
    return [];
  }

  // Mock backfill seeds wire rows directly (see connectMock), so these are
  // interface-compliance stubs — never exercised in the mock flow.
  async listChats(): Promise<{ chats: never[]; cursor: null }> { return { chats: [], cursor: null }; }
  async listMessages(): Promise<{ messages: never[]; cursor: null }> { return { messages: [], cursor: null }; }

  async sendMessage(_accountId: string, chatId: string, _text: string): Promise<{ messageId: string }> {
    return { messageId: `mock-sent-${chatId}-${crypto.randomUUID().slice(0, 8)}` };
  }
}

let instance: MockUnipileClient | null = null;
export function mockUnipile(): UnipileClient {
  instance ??= new MockUnipileClient();
  return instance;
}
