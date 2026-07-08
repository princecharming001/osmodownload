// POST /api/account/delete — purge every server-side record for this device
// (license, usage, connections, provider tokens, synced rows, the device
// itself). The app pairs this with a full LOCAL wipe. Irreversible.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { getAccounts } from "@/lib/accounts/store";

export async function POST(req: Request): Promise<Response> {
  try {
    const device = await requireDevice(req);
    getStore().purgeDevice(device.id);            // ephemeral sync/message state
    await getAccounts().purgeByDevice(device.id); // durable account + subscription
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
