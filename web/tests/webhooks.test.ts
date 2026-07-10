import { beforeEach, describe, expect, it } from "vitest";
import { ensureUnipileWebhooks, resetWebhookEnsureForTests } from "@/lib/unipile/webhooks";
import type { UnipileClient, UnipileWebhook } from "@/lib/unipile/client";

const PUBLIC_URL = "https://tunnel.example.com";
const TARGET = `${PUBLIC_URL}/api/webhooks/unipile`;

function fakeClient(existing: UnipileWebhook[]): UnipileClient & {
  created: { name: string; source: string; requestUrl: string }[];
  deleted: string[];
} {
  const created: { name: string; source: string; requestUrl: string }[] = [];
  const deleted: string[] = [];
  return {
    mode: "live",
    async createHostedAuthLink() { return { url: "" }; },
    async listAccounts() { return []; },
    async listChats() { return { chats: [], cursor: null }; },
    async listChatAttendees() { return []; },
    async getUserProfile() { return null; },
    async listMessages() { return { messages: [], cursor: null }; },
    async listChatMessages() { return { messages: [], cursor: null }; },
    async sendMessage() { return { messageId: "" }; },
    async downloadAttachment() { return null; },
    async listWebhooks() { return existing; },
    async createWebhook(opts) {
      created.push(opts);
      return { id: `new-${created.length}`, ...opts };
    },
    async deleteWebhook(id) { deleted.push(id); },
    created, deleted,
  };
}

beforeEach(() => { resetWebhookEnsureForTests(); });

describe("ensureUnipileWebhooks", () => {
  it("registers both hooks when absent", async () => {
    const client = fakeClient([]);
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    expect(client.created).toHaveLength(2);
    expect(client.created.map((c) => c.name).sort()).toEqual(["osmo-account-status", "osmo-messaging"]);
    expect(client.created.every((c) => c.requestUrl === TARGET)).toBe(true);
    expect(client.deleted).toHaveLength(0);
  });

  it("no-ops when both hooks already point at the target URL", async () => {
    const client = fakeClient([
      { id: "h1", name: "osmo-messaging", source: "messaging", requestUrl: TARGET },
      { id: "h2", name: "osmo-account-status", source: "account_status", requestUrl: TARGET },
    ]);
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    expect(client.created).toHaveLength(0);
    expect(client.deleted).toHaveLength(0);
  });

  it("recreates a hook whose URL is stale (a new tunnel came up)", async () => {
    const client = fakeClient([
      { id: "h1", name: "osmo-messaging", source: "messaging", requestUrl: "https://old-tunnel.example.com/api/webhooks/unipile" },
    ]);
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    expect(client.deleted).toEqual(["h1"]);
    expect(client.created).toHaveLength(2);   // messaging (stale, recreated) + account-status (absent)
  });

  it("never touches a webhook it didn't create (foreign name, tenant-wide key)", async () => {
    const client = fakeClient([
      { id: "foreign-1", name: "some-other-app-hook", source: "messaging", requestUrl: "https://elsewhere.example.com/hook" },
    ]);
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    expect(client.deleted).not.toContain("foreign-1");
    // Both osmo hooks still get created since they weren't found by name.
    expect(client.created.map((c) => c.name).sort()).toEqual(["osmo-account-status", "osmo-messaging"]);
  });

  it("is a no-op without a live key or without PUBLIC_URL", async () => {
    const client = fakeClient([]);
    await ensureUnipileWebhooks({ client, live: false, publicURL: PUBLIC_URL });
    expect(client.created).toHaveLength(0);
    resetWebhookEnsureForTests();
    await ensureUnipileWebhooks({ client, live: true, publicURL: undefined });
    expect(client.created).toHaveLength(0);
  });

  it("only does the real work once per process (idempotent)", async () => {
    const client = fakeClient([]);
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    await ensureUnipileWebhooks({ client, live: true, publicURL: PUBLIC_URL });
    expect(client.created).toHaveLength(2);   // not 4 — the second call no-ops
  });
});
