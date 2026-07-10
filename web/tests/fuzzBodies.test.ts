// Table-driven body fuzz: EVERY POST route that reads a JSON body must answer
// junk — `null` (valid JSON!), arrays, proto-pollution probes, megabyte
// strings, invalid JSON, wrong content-type — with a 4xx/2xx, never a 500.
// The old `.json().catch(() => ({}))` idiom crashed on `null` (`body.field`
// on null throws), which is exactly what this pins.

import { beforeEach, describe, expect, it } from "vitest";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { resetAccountsForTests } from "@/lib/accounts/store";
import { resetEventsForTests } from "@/lib/connections/events";
import { NextRequest } from "next/server";
import { POST as register } from "@/app/api/device/register/route";
import { POST as suggest } from "@/app/api/suggest/route";
import { POST as send } from "@/app/api/sync/send/route";
import { POST as connectLink } from "@/app/api/connect/link/route";
import { POST as rebackfill } from "@/app/api/connect/rebackfill/route";
import { POST as mockComplete } from "@/app/api/connect/mock/complete/route";
import { POST as notify } from "@/app/api/connect/notify/route";
import { POST as feedback } from "@/app/api/feedback/route";
import { POST as authRequest } from "@/app/api/auth/request/route";
import { POST as accountLink } from "@/app/api/account/link/route";
import { POST as accountUpgrade } from "@/app/api/account/upgrade/route";
import { POST as promoRedeem } from "@/app/api/promo/redeem/route";
import { POST as checkoutSession } from "@/app/api/checkout/session/route";
import { POST as licenseValidate } from "@/app/api/license/validate/route";
import { POST as enrichPerson } from "@/app/api/enrich/person/route";
import { POST as devEmit } from "@/app/api/dev/emit/route";
import { PATCH as accountsPatch } from "@/app/api/accounts/route";
import { POST as webhook } from "@/app/api/webhooks/unipile/route";

const BASE = "http://localhost:3000";

type Handler = (req: never) => Promise<Response>;

const ROUTES: { name: string; path: string; handler: Handler; auth: boolean; next?: boolean }[] = [
  { name: "suggest", path: "/api/suggest", handler: suggest as unknown as Handler, auth: true, next: true },
  { name: "sync/send", path: "/api/sync/send", handler: send as unknown as Handler, auth: true },
  { name: "connect/link", path: "/api/connect/link", handler: connectLink as unknown as Handler, auth: true },
  { name: "connect/rebackfill", path: "/api/connect/rebackfill", handler: rebackfill as unknown as Handler, auth: true },
  { name: "connect/mock/complete", path: "/api/connect/mock/complete", handler: mockComplete as unknown as Handler, auth: false },
  { name: "connect/notify", path: "/api/connect/notify", handler: notify as unknown as Handler, auth: false },
  { name: "feedback", path: "/api/feedback", handler: feedback as unknown as Handler, auth: true },
  { name: "auth/request", path: "/api/auth/request", handler: authRequest as unknown as Handler, auth: false },
  { name: "account/link", path: "/api/account/link", handler: accountLink as unknown as Handler, auth: true },
  { name: "account/upgrade", path: "/api/account/upgrade", handler: accountUpgrade as unknown as Handler, auth: false },
  { name: "promo/redeem", path: "/api/promo/redeem", handler: promoRedeem as unknown as Handler, auth: true },
  { name: "checkout/session", path: "/api/checkout/session", handler: checkoutSession as unknown as Handler, auth: true },
  { name: "license/validate", path: "/api/license/validate", handler: licenseValidate as unknown as Handler, auth: true },
  { name: "enrich/person", path: "/api/enrich/person", handler: enrichPerson as unknown as Handler, auth: true },
  { name: "dev/emit", path: "/api/dev/emit", handler: devEmit as unknown as Handler, auth: true },
  { name: "accounts PATCH", path: "/api/accounts?id=x", handler: accountsPatch as unknown as Handler, auth: true },
  { name: "webhooks/unipile", path: "/api/webhooks/unipile", handler: webhook as unknown as Handler, auth: false },
];

const BODIES: { label: string; body: string; contentType?: string }[] = [
  { label: "JSON null", body: "null" },
  { label: "JSON array", body: "[]" },
  { label: "proto-pollution probe", body: '{"__proto__":{"polluted":true}}' },
  { label: "bare JSON string", body: '"a string, not an object"' },
  { label: "1MB string body", body: JSON.stringify("x".repeat(1_000_000)) },
  { label: "invalid JSON", body: "not json {{{" },
  { label: "wrong content-type", body: "field=value&other=1", contentType: "application/x-www-form-urlencoded" },
];

beforeEach(() => { resetStoreForTests(); resetAccountsForTests(); resetEventsForTests(); });

describe("POST body fuzz — junk never 500s", () => {
  for (const { label, body, contentType } of BODIES) {
    it(`every body-reading route survives: ${label}`, async () => {
      const token = (await (await register()).json()).deviceToken as string;
      for (const route of ROUTES) {
        const method = route.name === "accounts PATCH" ? "PATCH" : "POST";
        const init: RequestInit = {
          method,
          headers: {
            "content-type": contentType ?? "application/json",
            ...(route.auth ? { authorization: `Bearer ${token}` } : {}),
          },
          body,
        };
        const req = route.next
          ? new NextRequest(`${BASE}${route.path}`, init as ConstructorParameters<typeof NextRequest>[1])
          : new Request(`${BASE}${route.path}`, init);
        const res = await route.handler(req as never);
        expect(res.status, `${route.name} · ${label} → ${res.status}`).toBeLessThan(500);
      }
    });
  }

  it("prototype was not actually polluted by the probe", () => {
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });
});
