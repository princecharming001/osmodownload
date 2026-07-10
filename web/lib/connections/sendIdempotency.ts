// Send idempotency — remembers the message a (device, idempotencyKey) send
// produced, so a retry after a lost response returns the SAME message instead of
// delivering a duplicate to the recipient. Per-process for now; moves to the
// durable send_outbox table under 0-B (D4).

import type { WireMessage } from "./types";

const g = globalThis as unknown as {
  __osmoSendIdem?: Map<string, WireMessage>;
  __osmoSendPending?: Map<string, Promise<WireMessage>>;
};
function map(): Map<string, WireMessage> { return (g.__osmoSendIdem ??= new Map()); }
function pending(): Map<string, Promise<WireMessage>> { return (g.__osmoSendPending ??= new Map()); }

export function recallSend(deviceId: string, key: string): WireMessage | undefined {
  return map().get(`${deviceId}:${key}`);
}
export function rememberSend(deviceId: string, key: string, msg: WireMessage): void {
  map().set(`${deviceId}:${key}`, msg);
}

/** Run `send` at most once per (device, key) — INCLUDING concurrently. The
    completed-send map alone can't stop a rapid double-POST (both requests read
    it before either writes), so the first caller parks its in-flight promise
    and the second awaits that same promise instead of delivering a duplicate.
    A FAILED send is not cached: the client's retry gets a fresh attempt. */
export async function sendOnce(
  deviceId: string, key: string, send: () => Promise<WireMessage>,
): Promise<WireMessage> {
  const mapKey = `${deviceId}:${key}`;
  const prior = map().get(mapKey);
  if (prior) return prior;
  const inFlight = pending().get(mapKey);
  if (inFlight) return inFlight;
  const p = (async () => {
    const msg = await send();
    map().set(mapKey, msg);
    return msg;
  })();
  pending().set(mapKey, p);
  try {
    return await p;
  } finally {
    pending().delete(mapKey);
  }
}

export function resetSendIdempotencyForTests(): void {
  g.__osmoSendIdem = new Map();
  g.__osmoSendPending = new Map();
}
