import { describe, it, expect, afterEach } from "vitest";
import { backfillScope, envInt, makeConversationGate } from "@/lib/connections/scope";
import { deepFetchScope } from "@/lib/connections/deepFetch";

describe("backfill scope", () => {
  afterEach(() => {
    delete process.env.OSMO_BACKFILL_SCOPE;
    delete process.env.OSMO_BACKFILL_DAYS;
  });

  it("defaults to the 30-day (1 month) unlimited pull", () => {
    delete process.env.OSMO_BACKFILL_SCOPE;
    const s = backfillScope();
    expect(s.sinceMs).toBe(30 * 24 * 3600 * 1000);
    expect(s.maxConversations).toBeNull();
  });

  it("OSMO_BACKFILL_DAYS widens the window without a deploy", () => {
    process.env.OSMO_BACKFILL_DAYS = "90";
    expect(backfillScope().sinceMs).toBe(90 * 24 * 3600 * 1000);
  });

  it("envInt falls back on unset/garbage/non-positive values", () => {
    delete process.env.OSMO_BACKFILL_DAYS;
    expect(envInt("OSMO_BACKFILL_DAYS", 30)).toBe(30);
    process.env.OSMO_BACKFILL_DAYS = "banana";
    expect(envInt("OSMO_BACKFILL_DAYS", 30)).toBe(30);
    process.env.OSMO_BACKFILL_DAYS = "0";
    expect(envInt("OSMO_BACKFILL_DAYS", 30)).toBe(30);
    process.env.OSMO_BACKFILL_DAYS = "45";
    expect(envInt("OSMO_BACKFILL_DAYS", 30)).toBe(45);
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

describe("deep-fetch scope", () => {
  afterEach(() => {
    delete process.env.OSMO_BACKFILL_SCOPE;
    delete process.env.OSMO_DEEP_FETCH_CONVERSATIONS;
    delete process.env.OSMO_DEEP_FETCH_MESSAGES;
  });

  it("defaults to 10 conversations × 100 messages", () => {
    const s = deepFetchScope();
    expect(s.conversations).toBe(10);
    expect(s.messagesPerConversation).toBe(100);
  });

  it("demo scope shrinks the conversation count to 2", () => {
    process.env.OSMO_BACKFILL_SCOPE = "demo";
    const s = deepFetchScope();
    expect(s.conversations).toBe(2);
    expect(s.messagesPerConversation).toBe(100);
  });

  it("env overrides win — even over the demo shrink", () => {
    process.env.OSMO_DEEP_FETCH_CONVERSATIONS = "4";
    process.env.OSMO_DEEP_FETCH_MESSAGES = "250";
    expect(deepFetchScope()).toEqual({ conversations: 4, messagesPerConversation: 250 });
    process.env.OSMO_BACKFILL_SCOPE = "demo";
    expect(deepFetchScope().conversations).toBe(4);
  });
});
