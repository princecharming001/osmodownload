// The oplog/cursor/dedup contract — the load-bearing store mechanics.

import { beforeEach, describe, expect, it } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import type { WireMessage } from "@/lib/connections/types";

const msg = (id: string, text = "hey", readAt: string | null = null): WireMessage => ({
  platform: "linkedin", platformMessageID: id, platformThreadID: "t1",
  senderHandle: "urn:li:member:1", isFromMe: false, text,
  sentAt: "2026-07-01T09:00:00Z", readAt,
});

describe("memory store oplog", () => {
  beforeEach(() => resetStoreForTests());

  it("registers devices and finds them by token only", () => {
    const d = getStore().registerDevice();
    expect(getStore().deviceByToken(d.token)?.id).toBe(d.id);
    expect(getStore().deviceByToken("nope")).toBeNull();
  });

  it("identical rows do not burn seq; changed rows do", () => {
    const s = getStore();
    const d = s.registerDevice();
    const first = s.appendRows(d.id, { messages: [msg("m1")] });
    expect(first).toBe(1);
    // Same content → no-op.
    expect(s.appendRows(d.id, { messages: [msg("m1")] })).toBe(1);
    // Read receipt arrived → content changed → new seq so cursors pick it up.
    expect(s.appendRows(d.id, { messages: [msg("m1", "hey", "2026-07-01T09:05:00Z")] })).toBe(2);
  });

  it("pull pages ascending with hasMore and echoes cursor when empty", () => {
    const s = getStore();
    const d = s.registerDevice();
    s.appendRows(d.id, { messages: [msg("m1"), msg("m2"), msg("m3")] });

    const page1 = s.pull(d.id, 0, 2);
    expect(page1.messages.map(m => m.platformMessageID)).toEqual(["m1", "m2"]);
    expect(page1.hasMore).toBe(true);
    expect(page1.cursor).toBe("2");

    const page2 = s.pull(d.id, 2, 2);
    expect(page2.messages.map(m => m.platformMessageID)).toEqual(["m3"]);
    expect(page2.hasMore).toBe(false);

    const empty = s.pull(d.id, 3, 2);
    expect(empty.cursor).toBe("3");
    expect(empty.messages).toHaveLength(0);
  });

  it("pending links are single-use", () => {
    const s = getStore();
    const d = s.registerDevice();
    const link = s.createPendingLink(d.id, "linkedin");
    expect(s.resolvePendingLink(link.linkId)?.platform).toBe("linkedin");
    expect(s.resolvePendingLink(link.linkId)).toBeNull();
    expect(s.resolvePendingLink("link-unknown")).toBeNull();
  });

  it("keeps devices' oplogs isolated", () => {
    const s = getStore();
    const a = s.registerDevice();
    const b = s.registerDevice();
    s.appendRows(a.id, { messages: [msg("m1")] });
    expect(s.pull(b.id, 0, 10).messages).toHaveLength(0);
  });
});
