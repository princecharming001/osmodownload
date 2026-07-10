// D4: a retried send with the same idempotency key must not deliver a duplicate.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetEventsForTests } from "@/lib/connections/events";
import { sendOnce } from "@/lib/connections/sendIdempotency";
import type { WireMessage } from "@/lib/connections/types";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";
import { POST as send } from "@/app/api/sync/send/route";
import { GET as outbox } from "@/app/api/dev/outbox/route";

const BASE = "http://localhost:3000";
function req(path: string, token?: string, body?: object): Request {
  return new Request(`${BASE}${path}`, {
    method: body ? "POST" : "GET",
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

beforeEach(() => { resetStoreForTests(); resetEventsForTests(); process.env.OSMO_MOCK_DRIP_MS = "0"; });

describe("send idempotency", () => {
  it("a repeated idempotency key returns the same message and sends only once", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, { platform: "linkedin" }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));

    const payload = { platform: "linkedin", platformThreadID: "demo-li-chat-1", text: "hello once", idempotencyKey: "idem-123" };
    const first = await (await send(req("/api/sync/send", token, payload))).json();
    const second = await (await send(req("/api/sync/send", token, payload))).json();

    expect(second.message.platformMessageID).toBe(first.message.platformMessageID);
    const box = await (await outbox(req("/api/dev/outbox", token))).json();
    expect(box.outbox.filter((m: { text: string }) => m.text === "hello once")).toHaveLength(1);
  });

  it("a CONCURRENT double-POST with the same key delivers once (route level)", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const link = await (await connectLink(req("/api/connect/link", token, { platform: "linkedin" }))).json();
    await mockComplete(req("/api/connect/mock/complete", undefined, { linkId: link.linkId }));

    const payload = { platform: "linkedin", platformThreadID: "demo-li-chat-1", text: "racing", idempotencyKey: "idem-race" };
    const [a, b] = await Promise.all([
      send(req("/api/sync/send", token, payload)).then((r) => r.json()),
      send(req("/api/sync/send", token, payload)).then((r) => r.json()),
    ]);
    expect(a.message.platformMessageID).toBe(b.message.platformMessageID);
    const box = await (await outbox(req("/api/dev/outbox", token))).json();
    expect(box.outbox.filter((m: { text: string }) => m.text === "racing")).toHaveLength(1);
  });
});

describe("sendOnce — in-flight coalescing", () => {
  const wire = (id: string): WireMessage => ({
    platform: "linkedin", platformMessageID: id, platformThreadID: "t",
    senderHandle: null, isFromMe: true, text: "x", sentAt: new Date().toISOString(), readAt: null,
  });

  it("two overlapping calls run the send exactly once and share the result", async () => {
    let sends = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const slowSend = async () => { sends++; await gate; return wire(`sent-${sends}`); };

    const p1 = sendOnce("dev-1", "k1", slowSend);
    const p2 = sendOnce("dev-1", "k1", slowSend);   // arrives while p1 is in flight
    release();
    const [m1, m2] = await Promise.all([p1, p2]);
    expect(sends).toBe(1);
    expect(m2.platformMessageID).toBe(m1.platformMessageID);
  });

  it("a FAILED send is not cached — the retry gets a fresh attempt", async () => {
    let sends = 0;
    const flaky = async () => {
      sends++;
      if (sends === 1) throw new Error("provider down");
      return wire("second-try");
    };
    await expect(sendOnce("dev-1", "k2", flaky)).rejects.toThrow("provider down");
    const retry = await sendOnce("dev-1", "k2", flaky);
    expect(retry.platformMessageID).toBe("second-try");
    expect(sends).toBe(2);
  });

  it("different keys never coalesce", async () => {
    let sends = 0;
    const sendFn = async () => { sends++; return wire(`m-${sends}`); };
    const a = await sendOnce("dev-1", "ka", sendFn);
    const b = await sendOnce("dev-1", "kb", sendFn);
    expect(sends).toBe(2);
    expect(a.platformMessageID).not.toBe(b.platformMessageID);
  });
});
