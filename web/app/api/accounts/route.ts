// GET /api/accounts — the caller's connections + status (reconciliation
// snapshot for the app). PATCH ?id= {action:"pause"|"resume"} toggles sync.
// DELETE ?id= disconnects.

import { AuthError, requireDevice, unauthorized } from "@/lib/connections/auth";
import { getStore } from "@/lib/connections/memoryStore";
import { publish } from "@/lib/connections/events";
import { stopDrip } from "@/lib/unipile/mock";
import type { AccountsResponse } from "@/lib/connections/types";

export async function GET(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const connections = getStore().connections(device.id)
      .map(({ deviceId: _omit, ...rest }) => rest);
    const res: AccountsResponse = { connections };
    return Response.json(res);
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}

export async function PATCH(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const id = new URL(req.url).searchParams.get("id") ?? "";
    const body = await req.json().catch(() => ({}));
    const action = body.action as string | undefined;
    const store = getStore();
    const conn = store.connectionById(id);
    if (!conn || conn.deviceId !== device.id) {
      return Response.json({ error: "unknown connection" }, { status: 404 });
    }
    if (action === "pause") store.setConnectionStatus(id, "paused");
    else if (action === "resume") store.setConnectionStatus(id, "connected");
    else return Response.json({ error: "action must be pause|resume" }, { status: 400 });
    publish(device.id, {
      type: "connection.status", platform: conn.platform,
      status: action === "pause" ? "paused" : "connected", connectionId: id,
    });
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}

export async function DELETE(req: Request): Promise<Response> {
  try {
    const device = requireDevice(req);
    const id = new URL(req.url).searchParams.get("id") ?? "";
    const store = getStore();
    const conn = store.connectionById(id);
    if (!conn || conn.deviceId !== device.id) {
      return Response.json({ error: "unknown connection" }, { status: 404 });
    }
    stopDrip(id);
    store.removeConnection(id);
    publish(device.id, {
      type: "connection.status", platform: conn.platform,
      status: "disconnected", connectionId: id,
    });
    return Response.json({ ok: true });
  } catch (e) {
    if (e instanceof AuthError) return unauthorized();
    throw e;
  }
}
