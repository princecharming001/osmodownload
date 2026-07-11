// GET /api/version — the app's manual update-check stub (Sparkle later).

import { getUnipile } from "@/lib/unipile/client";
import { isLiveOAuth } from "@/lib/oauth/providers";

const CURRENT = {
  version: "0.2.0",
  build: 2,
  downloadURL: "https://osmo.app/download",
  notes: "Consumer redesign: platform connections, liquid-glass pill, new onboarding.",
};

export async function GET(): Promise<Response> {
  // `mode` is SERVER truth: any live provider (Unipile or OAuth) means real
  // data can flow. Clients re-read this per boot — a device credential file
  // must never brand an install "mock" forever (it did: a device registered
  // once against a keyless dev server kept canned demo answers even when
  // talking to production).
  const live = getUnipile().mode === "live"
    || isLiveOAuth("gmail") || isLiveOAuth("slack") || isLiveOAuth("x");
  return Response.json({ ...CURRENT, mode: live ? "live" : "mock" });
}
