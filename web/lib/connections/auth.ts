// Device-token auth for all app-facing routes. The Mac app registers once
// (POST /api/device/register), keeps the token in its Keychain, and sends
// `Authorization: Bearer <token>` on every call. Unknown token → 401; the app
// responds by re-registering and resetting its cursor (idempotent re-pull).

import type { Device } from "./types";
import { getStore } from "./memoryStore";

export class AuthError extends Error {
  constructor() { super("unauthorized"); }
}

/** Extract + validate the device from a request. Throws AuthError on failure. */
export function requireDevice(req: Request): Device {
  const header = req.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ")
    ? header.slice(7)
    : new URL(req.url).searchParams.get("token") ?? ""; // SSE browser-debug fallback
  const device = token ? getStore().deviceByToken(token) : null;
  if (!device) throw new AuthError();
  return device;
}

export function unauthorized(): Response {
  return Response.json({ error: "unauthorized" }, { status: 401 });
}
