// W4 — X backfill maps profile_image_url onto the contact, so X DM partners
// (who are non-connections by nature) get a photo, not a monogram.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getStore, resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { backfillX } from "@/lib/oauth/xBackfill";
import type { Connection } from "@/lib/connections/types";

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); });
afterEach(() => { vi.unstubAllGlobals(); });

describe("X backfill — avatar mapping", () => {
  it("maps profile_image_url (upgraded to _400x400) onto the DM partner's contact", async () => {
    const store = getStore();
    const device = store.registerDevice();
    const conn: Connection = {
      id: "x-1", deviceId: device.id, platform: "x", status: "backfilling",
      displayName: "X", backfillProgress: 0, createdAt: new Date().toISOString(),
    };
    store.addConnection(conn);

    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      if (url.includes("/users/me")) {
        return new Response(JSON.stringify({ data: { id: "ME" } }),
          { status: 200, headers: { "content-type": "application/json" } });
      }
      // dm_events page: one inbound message from user U1 with an avatar.
      return new Response(JSON.stringify({
        data: [{ id: "e1", event_type: "MessageCreate", text: "hey", created_at: new Date().toISOString(),
                 sender_id: "U1", dm_conversation_id: "C1" }],
        includes: { users: [{ id: "U1", name: "Rae", username: "rae",
                              profile_image_url: "https://pbs.twimg.com/profile_images/1/pic_normal.jpg" }] },
        meta: {},
      }), { status: 200, headers: { "content-type": "application/json" } });
    }));

    await backfillX(device.id, "x-1", "tok");

    const batch = store.pull(device.id, 0, 1000);
    const contact = batch.contacts.find((c) => c.handle === "rae");
    expect(contact).toBeDefined();
    expect(contact?.displayName).toBe("Rae");
    expect(contact?.avatarUrl).toBe("https://pbs.twimg.com/profile_images/1/pic_400x400.jpg");
  });
});
