import { describe, it, expect, afterEach } from "vitest";
import { backfillScope, makeConversationGate } from "@/lib/connections/scope";

describe("backfill scope", () => {
  afterEach(() => { delete process.env.OSMO_BACKFILL_SCOPE; });

  it("defaults to the 30-day (1 month) unlimited pull", () => {
    delete process.env.OSMO_BACKFILL_SCOPE;
    const s = backfillScope();
    expect(s.sinceMs).toBe(30 * 24 * 3600 * 1000);
    expect(s.maxConversations).toBeNull();
  });

  it("demo scope = 15 days, 5 conversations", () => {
    process.env.OSMO_BACKFILL_SCOPE = "demo";
    const s = backfillScope();
    expect(s.sinceMs).toBe(15 * 24 * 3600 * 1000);
    expect(s.maxConversations).toBe(5);
  });

  it("gate admits the first N distinct conversations then only repeats", () => {
    const gate = makeConversationGate(2);
    expect(gate("a")).toBe(true);   // 1st distinct
    expect(gate("b")).toBe(true);   // 2nd distinct
    expect(gate("a")).toBe(true);   // repeat of admitted
    expect(gate("c")).toBe(false);  // over the cap
    expect(gate("b")).toBe(true);   // repeats still fine
    expect(gate("c")).toBe(false);  // stays out
  });

  it("null cap admits everything", () => {
    const gate = makeConversationGate(null);
    for (const id of ["a", "b", "c", "d", "e", "f"]) expect(gate(id)).toBe(true);
  });

  it("newest-first stream → the gate keeps exactly the most recent conversations", () => {
    // Simulates the account-wide newest-first message stream: chats appear in
    // order of last activity. Cap 5 → chats f..j (older) are excluded entirely.
    const gate = makeConversationGate(5);
    const stream = ["a", "b", "a", "c", "d", "b", "e", "f", "a", "g", "h", "e"];
    const kept = stream.filter((id) => gate(id));
    expect(new Set(kept)).toEqual(new Set(["a", "b", "c", "d", "e"]));
  });
});
