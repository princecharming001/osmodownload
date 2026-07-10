// Ingestion depth (workstream C): Unipile chat-list pagination, the deep
// per-conversation fetch on both the Unipile and Gmail importers, and the
// env caps that bound them. Unipile HTTP is faked the repo way — live env
// vars + a stubbed global fetch.

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

beforeEach(() => {
  resetStoreForTests();
  resetAccountsForTests();
  process.env.UNIPILE_DSN = "https://unipile.test";
  process.env.UNIPILE_API_KEY = "k";
});
afterEach(() => {
  delete process.env.UNIPILE_DSN;
  delete process.env.UNIPILE_API_KEY;
  delete process.env.OSMO_UNIPILE_MAX_CHAT_PAGES;
  delete process.env.OSMO_DEEP_FETCH_CONVERSATIONS;
  delete process.env.OSMO_DEEP_FETCH_MESSAGES;
  vi.unstubAllGlobals();
});

describe("unipile backfill — chat-list pagination", () => {
  it("follows the cursor across pages and stops on null", async () => {
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    const chatCursors: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats?")) {
        const cursor = new URL(u).searchParams.get("cursor");
        chatCursors.push(cursor ?? "first");
        const idx = cursor ? Number(cursor.slice(1)) : 0;
        return json({
          items: [{ id: `chat-${idx}`, name: `Chat ${idx}` }],
          cursor: idx < 2 ? `p${idx + 1}` : null,   // 3 pages total
        });
      }
      if (u.includes("/api/v1/messages?")) return json({ items: [], cursor: null });
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(chatCursors).toEqual(["first", "p1", "p2"]);
  });

  it("OSMO_UNIPILE_MAX_CHAT_PAGES caps a never-ending cursor", async () => {
    process.env.OSMO_UNIPILE_MAX_CHAT_PAGES = "2";
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));
    let chatCalls = 0;
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.includes("/api/v1/chats?")) {
        chatCalls++;
        return json({ items: [], cursor: `p${chatCalls}` });   // cursor never ends
      }
      if (u.includes("/api/v1/messages?")) return json({ items: [], cursor: null });
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    expect(chatCalls).toBe(2);
  });
});

describe("unipile backfill — deep per-conversation fetch", () => {
  it("pages the first N distinct chats off the newest-first stream, to the message cap", async () => {
    process.env.OSMO_DEEP_FETCH_CONVERSATIONS = "2";
    process.env.OSMO_DEEP_FETCH_MESSAGES = "3";
    const device = getStore().registerDevice();
    getStore().addConnection(connection("acc-1", device.id, "linkedin"));

    const now = new Date().toISOString();
    const deepCalls: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      const deep = u.match(/\/api\/v1\/chats\/([^/?]+)\/messages/);
      if (deep) {
        deepCalls.push(deep[1]);
        // Two messages per page, cursor never null → the message cap must stop it.
        const n = deepCalls.length;
        return json({
          items: [
            { id: `deep-${deep[1]}-${n}a`, chat_id: deep[1], text: "old context", timestamp: now },
            { id: `deep-${deep[1]}-${n}b`, chat_id: deep[1], text: "older context", timestamp: now },
          ],
          cursor: `more-${n}`,
        });
      }
      if (u.includes("/attendees")) return json({ items: [] });
      if (u.includes("/api/v1/chats?")) return json({ items: [], cursor: null });
      if (u.includes("/api/v1/messages?")) {
        // Newest-first sweep: chats A, A, B, C.
        return json({
          items: [
            { id: "m1", chat_id: "A", text: "hi", timestamp: now },
            { id: "m2", chat_id: "A", text: "hey", timestamp: now },
            { id: "m3", chat_id: "B", text: "yo", timestamp: now },
            { id: "m4", chat_id: "C", text: "sup", timestamp: now },
          ],
          cursor: null,
        });
      }
      return json({ items: [] });
    }));

    await backfillConnection({ deviceId: device.id, accountId: "acc-1", platform: "linkedin" });
    // First 2 distinct chat ids (A, B) get the deep pass — C does not; the
    // 3-message cap stops each chat after its second 2-message page.
    expect(deepCalls).toEqual(["A", "A", "B", "B"]);
    const pulled = getStore().pull(device.id, 0, 1000);
    const ids = pulled.messages.map((m) => m.platformMessageID);
    expect(ids).toContain("deep-A-1a");
    expect(ids).toContain("deep-B-3a");
    // Backfill completion stamps lastSyncAt.
    expect(getStore().connectionById("acc-1")?.lastSyncAt).toBeTruthy();
  });
});

describe("gmail backfill — deep thread fetch", () => {
  it("pulls the top-N most-recent NON-automated threads in full", async () => {
    process.env.OSMO_DEEP_FETCH_CONVERSATIONS = "2";
    const device = getStore().registerDevice();
    getStore().addConnection(connection("gconn", device.id, "gmail"));

    const b64 = (s: string) => Buffer.from(s, "utf-8").toString("base64url");
    const base = Date.now();
    const full = (id: string, tid: string, from: string, subject: string, ageMs: number) => ({
      id, threadId: tid, internalDate: String(base - ageMs), snippet: "…",
      payload: {
        mimeType: "text/plain",
        headers: [{ name: "From", value: from }, { name: "Subject", value: subject }],
        body: { data: b64("body text") },
      },
    });

    const deepCalls: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL) => {
      const u = String(url);
      if (u.endsWith("/profile")) return json({ emailAddress: "me@self.com" });
      const thread = u.match(/\/threads\/([^/?]+)/);
      if (thread) {
        deepCalls.push(thread[1]);
        return json({ messages: [full(`deep-${thread[1]}`, thread[1], "Sara <sara.lee@gmail.com>", "re: plans", 9_000)] });
      }
      if (u.includes("/messages/m1")) return json(full("m1", "tB", "Partiful <events@partiful.com>", "You're invited to Poker Night", 1_000));
      if (u.includes("/messages/m2")) return json(full("m2", "tA", "Sara <sara.lee@gmail.com>", "dinner?", 2_000));
      if (u.includes("/messages/m3")) return json(full("m3", "tC", "Jordan <jordan@brightlabs.io>", "following up from the conference", 3_000));
      if (u.includes("/messages?")) {
        return json({ messages: [{ id: "m1", threadId: "tB" }, { id: "m2", threadId: "tA" }, { id: "m3", threadId: "tC" }] });
      }
      return json({});
    }));

    await backfillGmail(device.id, "gconn", "tok");
    // tB is the newest thread but AUTOMATED → skipped; tA then tC by recency.
    expect(deepCalls).toEqual(["tA", "tC"]);
    const pulled = getStore().pull(device.id, 0, 1000);
    const ids = pulled.messages.map((m) => m.platformMessageID);
    expect(ids).toContain("deep-tA");
    expect(ids).toContain("deep-tC");
    // The automated thread still carries its hint for the client classifier.
    expect(pulled.threads.find((t) => t.platformThreadID === "tB")?.automatedHint).toBe(true);
    expect(getStore().connectionById("gconn")?.status).toBe("connected");
    expect(getStore().connectionById("gconn")?.lastSyncAt).toBeTruthy();
  });
});
