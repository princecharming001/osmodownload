// A provider outage (e.g. Unipile "no_client_session" when the instance's
// session/subscription lapses) must surface as a TYPED 503 from
// /api/connect/link — not an unhandled 500 — so the app can explain it
// honestly instead of looking like an Osmo bug.

import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/unipile/client", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/unipile/client")>();
  return {
    ...real,
    getUnipile: () => ({
      mode: "live" as const,
      createHostedAuthLink: async () => {
        throw new Error('unipile /api/v1/hosted/accounts/link → 503: {"type":"errors/no_client_session"}');
      },
    }),
  };
});

import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetEventsForTests } from "@/lib/connections/events";
import { POST as register } from "@/app/api/device/register/route";
import { POST as connectLink } from "@/app/api/connect/link/route";

const BASE = "http://localhost:3000";
function req(path: string, token?: string, body?: object): Request {
  return new Request(`${BASE}${path}`, {
    method: body ? "POST" : "GET",
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetEventsForTests(); });

describe("connect/link during a provider outage", () => {
  it("maps a hosted-auth provider failure to a typed 503, not a 500", async () => {
    const token = (await (await register()).json()).deviceToken as string;
    const res = await connectLink(req("/api/connect/link", token, { platform: "linkedin" }));
    expect(res.status).toBe(503);
    const body = await res.json();
    expect(body.error).toBe("provider_unavailable");
  });
});
