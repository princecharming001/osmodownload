// Backfill reliability: the import must always drive the connection to a
// TERMINAL state (connected/degraded — never stuck "backfilling"), must never
// override a user pause, and must not spin on an upstream that echoes the same
// pagination cursor back. Unipile HTTP is faked the repo way — live env vars +
// a stubbed global fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { backfillConnection } from "@/lib/connections/backfill";
import { backfillGmail } from "@/lib/oauth/gmailBackfill";
import type { Connection, Platform } from "@/lib/connections/types";

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200, headers: { "content-type": "application/json" },
  });
}

function connection(id: string, deviceId: string, platform: Platform): Connection {
  return {
    id, deviceId, platform, status: "backfilling",
    displayName: platform, backfillProgress: 0, createdAt: new Date().toISOString(),
  };
}

const msg = (i: number) => ({
  id: `m-${i}`, chat_id: "chat-1", text: `msg ${i}`,
  timestamp: new Date().toISOString(), is_sender: false, sender_attendee_id: "a-1",
});

beforeEach(() => {
  resetStoreForTests();
  resetAccountsForTests();
  process.env.UNIPILE_DSN = "https://unipile.test";
  process.env.UNIPILE_API_KEY = "k";
});
afterEach(() => {
  delete process.env.UNIPILE_DSN;
  delete process.env.UNIPILE_API_KEY;
  vi.unstubAllGlobals();
});

describe("backfill — terminal state guarantee", () => {
  it("a throw mid-message-pagination drives the status to degraded, never stuck backfilling", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    let messageCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats?")) return json({ items: [], cursor: null });
      if (u.includes("/api/v1/messages?")) {
        messageCalls++;
        if (messageCalls === 2) return new Response("boom", { status: 500 });   // mid-pagination
        return json({ items: [msg(messageCalls)], cursor: `p${messageCalls}` });
      }
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(messageCalls).toBe(2);
    expect(getStore().connectionById("acc-1")?.status).toBe("degraded");   // terminal, retryable
  });

  it("a clean run ends connected with progress 1", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/messages?")) return json({ items: [msg(1)], cursor: null });
      return json({ items: [], cursor: null });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    const conn = getStore().connectionById("acc-1");
    expect(conn?.status).toBe("connected");
    expect(conn?.backfillProgress).toBe(1);
  });
});

describe("backfill — pause is never overridden", () => {
  it("a pause that lands mid-import stays paused (not re-flipped to connected)", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    let messageCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats?")) return json({ items: [], cursor: null });
      if (u.includes("/api/v1/messages?")) {
        messageCalls++;
        // The user hits pause while this page is in flight.
        getStore().setConnectionStatus("acc-1", "paused");
        return json({ items: [msg(messageCalls)], cursor: `p${messageCalls}` });
      }
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(messageCalls).toBe(1);   // loop bailed on the pause
    expect(getStore().connectionById("acc-1")?.status).toBe("paused");   // NOT "connected"
  });
});

describe("backfill — pagination loop guards", () => {
  it("an upstream echoing the SAME sweep cursor stops instead of spinning to the page ceiling", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    let messageCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats?")) return json({ items: [], cursor: null });
      if (u.includes("/api/v1/messages?")) {
        messageCalls++;
        return json({ items: [msg(messageCalls)], cursor: "STUCK" });   // same cursor forever
      }
      return json({ items: [], cursor: null });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(messageCalls).toBe(2);   // first page (→STUCK) + one repeat, then the guard breaks
    expect(getStore().connectionById("acc-1")?.status).toBe("connected");
  });

  it("the deep per-chat pass cannot spin on junk pages with fresh-but-useless cursors", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    let deepCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats/chat-1/messages")) {
        deepCalls++;
        // Non-empty pages whose rows never normalize (no id/chat_id) and a
        // cursor that repeats — `collected` never grows.
        return json({ items: [{ junk: true }], cursor: "SAME" });
      }
      if (u.includes("/api/v1/chats?")) return json({ items: [], cursor: null });
      if (u.includes("/api/v1/messages?")) return json({ items: [msg(1)], cursor: null });
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(deepCalls).toBe(2);   // repeat cursor → guard breaks (was: unbounded while-loop)
    expect(getStore().connectionById("acc-1")?.status).toBe("connected");
  });

  it("gmail list paging stops on an echoed nextPageToken but still crosses EMPTY pages", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("gconn", device.id, "gmail"));

    const b64 = (s: string) => Buffer.from(s, "utf-8").toString("base64url");
    let listCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.endsWith("/profile")) return json({ emailAddress: "me@self.com" });
      if (u.includes("/messages/m1")) {
        return json({
          id: "m1", threadId: "t1", internalDate: String(Date.now()), snippet: "…",
          payload: {
            mimeType: "text/plain",
            headers: [{ name: "From", value: "Sara <sara@example.com>" }, { name: "Subject", value: "hi" }],
            body: { data: b64("body") },
          },
        });
      }
      if (u.includes("/messages?")) {
        listCalls++;
        // Page 1: EMPTY but cursored (a real messages.list quirk with q filters)
        // — must NOT stop the import. Pages 2+: echo the same token forever.
        if (listCalls === 1) return json({ messages: [], nextPageToken: "T1" });
        return json({ messages: listCalls === 2 ? [{ id: "m1", threadId: "t1" }] : [], nextPageToken: "T2" });
      }
      return json({});
    }));

    await backfillGmail(device.id, "gconn", "tok");
    expect(listCalls).toBe(3);   // empty page crossed, then the echoed-token guard breaks
    const pulled = getStore().pull(device.id, 0, 1000);
    expect(pulled.messages.map((m) => m.platformMessageID)).toContain("m1");
    expect(getStore().connectionById("gconn")?.status).toBe("connected");
  });
});
