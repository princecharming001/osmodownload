// POST /api/device/register — mint device credentials. Always succeeds keyless;
// the Mac keeps the token in its Keychain and re-registers on any 401.

import { getStore } from "@/lib/connections/memoryStore";
import { getAccounts } from "@/lib/accounts/store";
import { isLiveUnipile } from "@/lib/unipile/client";
import type { RegisterResponse } from "@/lib/connections/types";

export async function POST(): Promise<Response> {
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
