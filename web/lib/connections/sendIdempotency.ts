// Send idempotency — remembers the message a (device, idempotencyKey) send
// produced, so a retry after a lost response returns the SAME message instead of
// delivering a duplicate to the recipient. Per-process for now; moves to the
// durable send_outbox table under 0-B (D4).

import type { WireMessage } from "./types";

const g = globalThis as unknown as { __osmoSendIdem?: Map<string, WireMessage> };
function map(): Map<string, WireMessage> { return (g.__osmoSendIdem ??= new Map()); }

export function recallSend(deviceId: string, key: string): WireMessage | undefined {
  return map().get(`${deviceId}:${key}`);
}
export function rememberSend(deviceId: string, key: string, msg: WireMessage): void {
  map().set(`${deviceId}:${key}`, msg);
}
export function resetSendIdempotencyForTests(): void { g.__osmoSendIdem = new Map(); }
