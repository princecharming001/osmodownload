// Runtime posture helpers — tiny + dependency-free so any route can gate on them.
//
// isProduction() is the HARD gate for dev/mock-only surfaces (dev routes, mock
// checkout): they must be unreachable in production regardless of whether a
// provider (Unipile/Stripe) happens to be configured.
//
// The model allowlist is the server-side guard against a client forcing an
// arbitrary (expensive) Anthropic model. The client sends a model id; the proxy
// only honours ids the server allows. Phase 2's signed config registry will
// narrow/update this set, but the proxy ALWAYS enforces it.

export function isProduction(): boolean {
  return (process.env.OSMO_ENV ?? process.env.NODE_ENV) === "production";
}

export const DEFAULT_MODEL = process.env.OSMO_DEFAULT_MODEL ?? "claude-sonnet-5";

export function allowedModels(): string[] {
  const raw = process.env.OSMO_ALLOWED_MODELS;
  const list = raw ? raw.split(",").map((s) => s.trim()).filter(Boolean) : [DEFAULT_MODEL];
  // The default model is always allowed, even if an override list omits it.
  return list.includes(DEFAULT_MODEL) ? list : [DEFAULT_MODEL, ...list];
}

export function isModelAllowed(model: string): boolean {
  return allowedModels().includes(model);
}
