// D4: a retried send with the same idempotency key must not deliver a duplicate.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetEventsForTests } from "@/lib/connections/events";
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
});
