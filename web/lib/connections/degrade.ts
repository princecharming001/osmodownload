// Mark a device's connection for a platform as degraded (e.g. after an OAuth
// refresh failure) so the client prompts a reconnect instead of silently failing.

import { getStore } from "./memoryStore";
import type { Platform } from "./types";

export function markConnectionDegraded(deviceId: string, platform: Platform): void {
  const store = getStore();
  const conn = store.connections(deviceId).find((c) => c.platform === platform);
  if (conn) store.setConnectionStatus(conn.id, "degraded");
}
