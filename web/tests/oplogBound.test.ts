// OOM guard: the in-memory oplog is bounded per device (evicts oldest, which are
// already-pulled). Prevents unbounded heap growth on a long-lived instance.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import type { WireMessage } from "@/lib/connections/types";

function msg(i: number): WireMessage {
  return {
    platform: "linkedin", platformMessageID: `m${i}`, platformThreadID: "t",
    senderHandle: null, isFromMe: false, text: `msg ${i}`,
    sentAt: new Date(1700000000000 + i * 1000).toISOString(), readAt: null,
  };
}

beforeEach(() => resetStoreForTests());
afterEach(() => { delete process.env.OSMO_OPLOG_MAX; });

describe("oplog OOM bound", () => {
  it("retains only the last OSMO_OPLOG_MAX entries; recent messages still pull", () => {
    process.env.OSMO_OPLOG_MAX = "5";
    const store = getStore();
    for (let i = 0; i < 8; i++) store.appendRows("dev-1", { messages: [msg(i)] });

    const batch = store.pull("dev-1", 0, 100);
    expect(batch.messages).toHaveLength(5);
    expect(batch.messages.map((m) => m.text)).toEqual(["msg 3", "msg 4", "msg 5", "msg 6", "msg 7"]);
    expect(store.maxSeq("dev-1")).toBe(8); // seq keeps advancing (monotonic)
  });
});

describe("oplog truncated-window signal", () => {
  // The silent-gap bug: a cursor BELOW the evicted window used to jump straight
  // to the retained rows with no indication that everything in between was
  // gone. The client must be told the batch is not contiguous with its cursor.
  it("a cursor below the evicted window gets reset:true + oldestSeq", () => {
    process.env.OSMO_OPLOG_MAX = "5";
    const store = getStore();
    for (let i = 0; i < 8; i++) store.appendRows("dev-1", { messages: [msg(i)] }); // seqs 1..8, 1..3 evicted

    const gapped = store.pull("dev-1", 2, 100);   // cursor 2 < evicted-through 3
    expect(gapped.reset).toBe(true);
    expect(gapped.oldestSeq).toBe(4);             // the retained window starts at seq 4
    expect(gapped.messages.map((m) => m.text)).toEqual(["msg 3", "msg 4", "msg 5", "msg 6", "msg 7"]);
  });

  it("a cursor at or above the eviction boundary is contiguous — no reset", () => {
    process.env.OSMO_OPLOG_MAX = "5";
    const store = getStore();
    for (let i = 0; i < 8; i++) store.appendRows("dev-1", { messages: [msg(i)] });

    expect(store.pull("dev-1", 3, 100).reset).toBeUndefined(); // saw exactly through the evicted rows
    expect(store.pull("dev-1", 6, 100).reset).toBeUndefined(); // well inside the window
    expect(store.pull("dev-1", 6, 100).oldestSeq).toBe(4);     // window edge still advertised
  });

  it("a deliberate full re-pull (since=0) is not flagged as a gap", () => {
    process.env.OSMO_OPLOG_MAX = "5";
    const store = getStore();
    for (let i = 0; i < 8; i++) store.appendRows("dev-1", { messages: [msg(i)] });

    const full = store.pull("dev-1", 0, 100);
    expect(full.reset).toBeUndefined();
    expect(full.oldestSeq).toBe(4);
  });

  it("no eviction → neither oldestSeq nor reset appear (wire unchanged)", () => {
    const store = getStore();
    for (let i = 0; i < 4; i++) store.appendRows("dev-1", { messages: [msg(i)] });
    const batch = store.pull("dev-1", 1, 100);
    expect(batch.oldestSeq).toBeUndefined();
    expect(batch.reset).toBeUndefined();
  });
});
