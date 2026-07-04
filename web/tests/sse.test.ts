// SSE stream mechanics: framing, publish fanout, cleanup on cancel.

import { beforeEach, describe, expect, it } from "vitest";
import { makeSSEStream, publish, resetEventsForTests, subscriberCount } from "@/lib/connections/events";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { GET as events } from "@/app/api/events/route";
import { POST as register } from "@/app/api/device/register/route";

beforeEach(() => { resetStoreForTests(); resetEventsForTests(); });

async function readUntil(reader: ReadableStreamDefaultReader<Uint8Array>, needle: string, maxChunks = 5): Promise<string> {
  const decoder = new TextDecoder();
  let acc = "";
  for (let i = 0; i < maxChunks; i++) {
    const { value, done } = await reader.read();
    if (done) break;
    acc += decoder.decode(value, { stream: true });
    if (acc.includes(needle)) break;
  }
  return acc;
}

describe("SSE stream", () => {
  it("frames published events as data: lines", async () => {
    const stream = makeSSEStream("dev-1");
    const reader = stream.getReader();
    // Opening comment arrives first.
    expect(await readUntil(reader, ": connected")).toContain(": connected");
    publish("dev-1", { type: "sync.dirty", seq: 42 });
    const chunk = await readUntil(reader, "sync.dirty");
    expect(chunk).toContain(`data: {"type":"sync.dirty","seq":42}\n\n`);
    await reader.cancel();
  });

  it("cancel removes the subscriber; publish to nobody is a no-op", async () => {
    const stream = makeSSEStream("dev-2");
    const reader = stream.getReader();
    await readUntil(reader, ": connected");
    expect(subscriberCount("dev-2")).toBe(1);
    await reader.cancel();
    expect(subscriberCount("dev-2")).toBe(0);
    publish("dev-2", { type: "sync.dirty", seq: 1 });   // must not throw
  });

  it("per-device isolation: device A never sees device B events", async () => {
    const a = makeSSEStream("dev-A").getReader();
    await readUntil(a, ": connected");
    publish("dev-B", { type: "sync.dirty", seq: 7 });
    publish("dev-A", { type: "sync.dirty", seq: 9 });
    const chunk = await readUntil(a, "sync.dirty");
    expect(chunk).toContain('"seq":9');
    expect(chunk).not.toContain('"seq":7');
    await a.cancel();
  });

  it("the route requires auth and streams for a registered device", async () => {
    expect((await events(new Request("http://x/api/events"))).status).toBe(401);
    const creds = await (await register()).json();
    const res = await events(new Request("http://x/api/events", {
      headers: { authorization: `Bearer ${creds.deviceToken}` },
    }));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    await res.body!.cancel();
  });
});
