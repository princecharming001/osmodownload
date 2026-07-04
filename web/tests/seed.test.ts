// Demo seed determinism + webhook normalizer.

import { describe, expect, it } from "vitest";
import { demoConversations, dripMessage } from "@/lib/demo/seed";
import { normalizeMessageWebhook } from "@/lib/unipile/normalize";
import { CONNECTABLE } from "@/lib/connections/types";

describe("demo seed", () => {
  it("every connectable platform has seed content with stable native IDs", () => {
    for (const p of CONNECTABLE) {
      const a = demoConversations(p);
      const b = demoConversations(p);
      expect(a.messages!.length).toBeGreaterThan(0);
      // Determinism: identical IDs and text across calls.
      expect(a.messages!.map(m => m.platformMessageID)).toEqual(b.messages!.map(m => m.platformMessageID));
      // Every message's thread exists in the same bundle.
      const threadIDs = new Set(a.threads!.map(t => t.platformThreadID));
      for (const m of a.messages!) expect(threadIDs.has(m.platformThreadID)).toBe(true);
    }
  });

  it("drip messages have unique IDs per tick and land in an existing thread", () => {
    const seed = demoConversations("linkedin");
    const d0 = dripMessage("linkedin", 0)!;
    const d1 = dripMessage("linkedin", 1)!;
    expect(d0.messages![0].platformMessageID).not.toBe(d1.messages![0].platformMessageID);
    const threadIDs = new Set(seed.threads!.map(t => t.platformThreadID));
    expect(threadIDs.has(d0.messages![0].platformThreadID)).toBe(true);
    expect(d0.messages![0].isFromMe).toBe(false);
  });
});

describe("unipile webhook normalizer", () => {
  it("normalizes a message_received payload into wire rows", () => {
    const bundle = normalizeMessageWebhook({
      event: "message_received",
      account_id: "acc-1",
      account_type: "LINKEDIN",
      chat_id: "chat-99",
      message_id: "msg-77",
      message: "hello there",
      sender: { attendee_provider_id: "urn:li:member:5", attendee_name: "Ada" },
      timestamp: "2026-07-04T10:00:00Z",
    });
    expect(bundle).not.toBeNull();
    expect(bundle!.messages![0]).toMatchObject({
      platform: "linkedin", platformMessageID: "msg-77",
      platformThreadID: "chat-99", text: "hello there", isFromMe: false,
      senderHandle: "urn:li:member:5",
    });
    expect(bundle!.contacts![0].displayName).toBe("Ada");
    expect(bundle!.threads![0].platformThreadID).toBe("chat-99");
  });

  it("degrades to null on unknown provider or missing ids (never throws)", () => {
    expect(normalizeMessageWebhook({ account_type: "MYSPACE", chat_id: "c", message_id: "m" })).toBeNull();
    expect(normalizeMessageWebhook({ account_type: "LINKEDIN" })).toBeNull();
    expect(normalizeMessageWebhook({})).toBeNull();
  });
});
