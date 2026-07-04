// POST /api/device/register — mint device credentials. Always succeeds keyless;
// the Mac keeps the token in its Keychain and re-registers on any 401.

import { getStore } from "@/lib/connections/memoryStore";
import { isLiveUnipile } from "@/lib/unipile/client";
import type { RegisterResponse } from "@/lib/connections/types";

export async function POST(): Promise<Response> {
  const device = getStore().registerDevice();
  const body: RegisterResponse = {
    deviceId: device.id,
    deviceToken: device.token,
    mode: isLiveUnipile() ? "live" : "mock",
  };
  return Response.json(body);
}
