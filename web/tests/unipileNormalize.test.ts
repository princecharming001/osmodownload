// Group detection across real-world Unipile chat payload variants. The
// original check trusted numeric `type >= 2`; real IG payloads carry a STRING
// type — Number("group") is NaN, so every group imported as a 1:1.
import { describe, expect, it } from "vitest";
import { chatIndex } from "@/lib/unipile/normalize";

describe("chatIndex group detection", () => {
  const cases: [string, Record<string, unknown>, boolean][] = [
    ["explicit flag", { id: "c1", is_group: true }, true],
    ["string type", { id: "c2", type: "GROUP" }, true],
    ["string type lowercase", { id: "c3", type: "group_chat" }, true],
    ["numeric type 2", { id: "c4", type: 2 }, true],
    ["attendee count", { id: "c5", attendees_count: 4 }, true],
    ["attendee array", { id: "c6", attendees: [{}, {}, {}] }, true],
    ["1:1 numeric", { id: "c7", type: 0 }, false],
    ["1:1 string", { id: "c8", type: "single" }, false],
    ["1:1 two attendees", { id: "c9", attendees: [{}, {}] }, false],
    ["bare chat", { id: "c10" }, false],
  ];
  for (const [label, chat, expected] of cases) {
    it(label, () => {
      const map = chatIndex([chat as never]);
      expect(map.get(chat.id as string)?.isGroup).toBe(expected);
    });
  }
});
