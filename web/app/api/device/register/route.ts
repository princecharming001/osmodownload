// POST /api/device/register — mint device credentials. Always succeeds keyless;
// the Mac keeps the token in its Keychain and re-registers on any 401.

import { getStore } from "@/lib/connections/memoryStore";
import { getAccounts } from "@/lib/accounts/store";
import { isLiveUnipile } from "@/lib/unipile/client";
import { rateLimit, clientIp, tooMany } from "@/lib/rateLimit";
import type { RegisterResponse } from "@/lib/connections/types";

export async function POST(req?: Request): Promise<Response> {
  // Open device minting is an abuse vector (infinite fresh trials / quota resets);
  // cap per IP. Tests call register() with no request → limiter is skipped.
  if (req) {
    const r = rateLimit(`register:ip:${clientIp(req)}`, 30, 60 * 60_000);
    if (!r.ok) return tooMany(r.retryAfterSec);
  }
  const device = getStore().registerDevice();
  // Persist a durable copy in the accounts DB so the device can be linked to a
  // user (Sign in with Apple) and its subscription survives restarts.
  await getAccounts().upsertDevice(device.id, device.token);
  const body: RegisterResponse = {
    deviceId: device.id,
    deviceToken: device.token,
    mode: isLiveUnipile() ? "live" : "mock",
  };
  return Response.json(body);
}
