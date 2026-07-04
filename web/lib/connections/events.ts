// SSE fanout — per-device subscriber sets on globalThis (hot-reload safe).
// Events are DOORBELLS ({type:"sync.dirty",seq}) and status pings, never
// message bodies: on any doorbell the app runs the same cursor pull it runs on
// its reconciliation timer, so there is exactly one ingest path.

import type { OsmoEvent } from "./types";

type Controller = ReadableStreamDefaultController<Uint8Array>;

const g = globalThis as unknown as {
  __osmoSubscribers?: Map<string, Set<Controller>>;
};

function subscribers(): Map<string, Set<Controller>> {
  g.__osmoSubscribers ??= new Map();
  return g.__osmoSubscribers;
}

const encoder = new TextEncoder();

function frame(event: OsmoEvent): Uint8Array {
  return encoder.encode(`data: ${JSON.stringify(event)}\n\n`);
}

/** Push an event to every live stream for this device. Dead controllers are pruned. */
export function publish(deviceId: string, event: OsmoEvent): void {
  const subs = subscribers().get(deviceId);
  if (!subs) return;
  const payload = frame(event);
  for (const controller of [...subs]) {
    try { controller.enqueue(payload); }
    catch { subs.delete(controller); }
  }
}

/** Number of live subscribers (test/diagnostic surface). */
export function subscriberCount(deviceId: string): number {
  return subscribers().get(deviceId)?.size ?? 0;
}

const HEARTBEAT_MS = 25_000;

/** Build the SSE body stream for a device connection. */
export function makeSSEStream(deviceId: string): ReadableStream<Uint8Array> {
  let controller: Controller | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;

  return new ReadableStream<Uint8Array>({
    start(c) {
      controller = c;
      const set = subscribers().get(deviceId) ?? new Set<Controller>();
      set.add(c);
      subscribers().set(deviceId, set);
      // Open with a comment so proxies flush headers immediately.
      c.enqueue(encoder.encode(`: connected\n\n`));
      heartbeat = setInterval(() => {
        try { c.enqueue(encoder.encode(`: ping\n\n`)); }
        catch { /* cancelled between ticks */ }
      }, HEARTBEAT_MS);
    },
    cancel() {
      if (heartbeat) clearInterval(heartbeat);
      if (controller) subscribers().get(deviceId)?.delete(controller);
    },
  });
}

/** Test-only: drop all subscribers. */
export function resetEventsForTests(): void {
  g.__osmoSubscribers = new Map();
}
