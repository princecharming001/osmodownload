// GET /api/version — the app's manual update-check stub (Sparkle later).

const CURRENT = {
  version: "0.2.0",
  build: 2,
  downloadURL: "https://osmo.app/download",
  notes: "Consumer redesign: platform connections, liquid-glass pill, new onboarding.",
};

export async function GET(): Promise<Response> {
  return Response.json(CURRENT);
}
