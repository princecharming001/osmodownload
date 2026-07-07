import { describe, it, expect } from "vitest";
import { normalizeUnipileMessage, chatIndex } from "@/lib/unipile/normalize";

describe("Unipile fidelity — reactions, replies, sender attribution", () => {
  const chats = chatIndex([{ id: "chat1", name: null, type: 0 }]);

  it("extracts emoji reactions across payload variants", () => {
    const bundle = normalizeUnipileMessage({
      id: "m1", chat_id: "chat1", text: "great news", is_sender: 0,
      sender_attendee_id: "att9", timestamp: "2026-06-20T10:00:00Z",
      reactions: [
        { value: "❤️", sender_id: "att9", is_sender: false },
        { emoji: "👍", is_sender: true },
        { broken: true },
      ],
    }, "linkedin", chats)!;
    const m = bundle.messages![0];
    expect(m.reactions).toHaveLength(2);
    expect(m.reactions![0]).toEqual({ emoji: "❤️", senderHandle: "att9", isFromMe: false });
    expect(m.reactions![1].isFromMe).toBe(true);
  });

  it("extracts reply-to across direct and nested shapes", () => {
    const direct = normalizeUnipileMessage({
      id: "m2", chat_id: "chat1", text: "yes", quoted_message_id: "m1",
    }, "whatsapp", chats)!;
    expect(direct.messages![0].replyToMessageID).toBe("m1");

    const nested = normalizeUnipileMessage({
      id: "m3", chat_id: "chat1", text: "ok", quoted: { id: "m1" },
    }, "whatsapp", chats)!;
    expect(nested.messages![0].replyToMessageID).toBe("m1");

    const none = normalizeUnipileMessage({
      id: "m4", chat_id: "chat1", text: "plain",
    }, "whatsapp", chats)!;
    expect(none.messages![0].replyToMessageID).toBeNull();
  });

  it("no reactions field → undefined, not empty array noise", () => {
    const b = normalizeUnipileMessage({ id: "m5", chat_id: "chat1", text: "hi" }, "instagram", chats)!;
    expect(b.messages![0].reactions).toBeUndefined();
  });
});

describe("Group sender attribution — the chat-title leak (WhatsApp/IG root cause)", () => {
  it("a 1:1 message with no sender_name still falls back to the chat title", () => {
    const chats = chatIndex([{ id: "dm1", name: "Alex Rivera", type: 0 }]);
    const bundle = normalizeUnipileMessage({
      id: "m1", chat_id: "dm1", text: "hey", is_sender: 0, sender_attendee_id: "att1",
    }, "whatsapp", chats)!;
    expect(bundle.contacts![0].displayName).toBe("Alex Rivera");
  });

  it("a GROUP message with no sender_name does NOT inherit the group's title as the sender's name", () => {
    const chats = chatIndex([{ id: "grp1", name: "Trip Planning", type: 2 }]);
    const bundle = normalizeUnipileMessage({
      id: "m2", chat_id: "grp1", text: "I'm in", is_sender: 0, sender_attendee_id: "att2",
    }, "whatsapp", chats)!;
    // null, not "Trip Planning" — the backfill's attendee-enrichment pass is
    // what fills in the real per-person name from here.
    expect(bundle.contacts![0].displayName).toBeNull();
  });

  it("a GROUP message WITH an explicit sender_name still uses it", () => {
    const chats = chatIndex([{ id: "grp2", name: "Trip Planning", type: 2 }]);
    const bundle = normalizeUnipileMessage({
      id: "m3", chat_id: "grp2", text: "same", is_sender: 0,
      sender_attendee_id: "att3", sender_name: "Priya Shah",
    }, "instagram", chats)!;
    expect(bundle.contacts![0].displayName).toBe("Priya Shah");
  });
});
