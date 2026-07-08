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
