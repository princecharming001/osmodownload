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
    being forced to re-register, which would orphan its subscription. */
export async function resolveDevice(token: string): Promise<Device | null> {
  if (!token) return null;
  const store = getStore();
  const inMem = store.deviceByToken(token);
  if (inMem) return inMem;
  const durable = await getAccounts().deviceByToken(token);
  return durable ? store.adoptDevice(durable.id, durable.token) : null;
}

function tokenFrom(req: Request): string {
  const header = req.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ")
    ? header.slice(7)
    : new URL(req.url).searchParams.get("token") ?? ""; // SSE browser-debug fallback
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
