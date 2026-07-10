// Device-token auth for all app-facing routes. The Mac app registers once
// (POST /api/device/register), keeps the token in its Keychain, and sends
// `Authorization: Bearer <token>` on every call. Unknown token → 401; the app
// responds by re-registering and resetting its cursor (idempotent re-pull).

import type { Device } from "./types";
import { getStore } from "./memoryStore";
import { getAccounts } from "../accounts/store";

export class AuthError extends Error {
  constructor() { super("unauthorized"); }
}

/** Resolve a device token: in-memory map first, then the durable osmo_devices
    table. After a restart/redeploy the in-memory map is empty, but the token
    persists durably — recognising it (and rehydrating the map) stops the app
    being forced to re-register, which would orphan its subscription.

    A durable-store READ FAILURE is deliberately allowed to propagate (it is
    never caught and converted to null/AuthError here): "store down" must
    surface as a 5xx the app retries, not a 401 that makes it re-register as a
    fresh device and orphan its Pro/connections. */
export async function resolveDevice(token: string): Promise<Device | null> {
  if (!token) return null;
  const store = getStore();
  const inMem = store.deviceByToken(token);
  if (inMem) return inMem;
  const durable = await getAccounts().deviceByToken(token);
  return durable ? store.adoptDevice(durable.id, durable.token) : null;
}

function tokenFrom(req: Request): string {
  // Bearer only — no ?token= query fallback. A token in the URL leaks into
  // logs/Referer/history and now authenticates against the durable store, i.e.
  // full account access. The Mac app's SSE client sets the Authorization header.
  const header = req.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : "";
}

/** Extract + validate the device from a request. Throws AuthError on failure. */
export async function requireDevice(req: Request): Promise<Device> {
  const device = await resolveDevice(tokenFrom(req));
  if (!device) throw new AuthError();
  return device;
}

export function unauthorized(): Response {
  return Response.json({ error: "unauthorized" }, { status: 401 });
}
