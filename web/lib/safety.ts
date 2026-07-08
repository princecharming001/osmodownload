// Server-side Safety re-run — a faithful port of Sources/OsmoBrain/Safety.swift.
// The client checks this before sending, but the proxy MUST re-check so a direct
// caller can't bypass the guardrail and burn the key on coercion/deception.
// Keyword floor + co-occurrence; the model prompt carries the fuller policy.
// (D1b will layer an LLM safety classifier on top of this fast pre-filter.)

export interface SafetyVerdict { allow: boolean; reason?: string; }

export const SAFETY_REASON =
  "Osmo helps you communicate clearly and with empathy — not to manipulate or deceive " +
  "someone. Try reframing the goal around what you genuinely want them to understand.";

const HARD_REFUSALS = [
  "get them to send money", "get nudes", "get them to send pics",
  "someone who is drunk", "they are drunk", "underage", "a minor",
  "revenge", "make them jealous to", "isolate them from",
];

const MANIPULATIVE = [
  "manipulate", "gaslight", "coerce", "pressure them into",
  "guilt trip", "guilt-trip", "trick them", "deceive", "lie to them",
  "exploit their", "prey on", "wear them down",
];

/** Run over the request text (goal + intent + transcript, or the composed userTurn
 *  which contains them). Returns allow=false with a user-facing reason to refuse. */
export function checkSafety(text: string): SafetyVerdict {
  const hay = (text ?? "").toLowerCase();
  if (!hay.trim()) return { allow: true };
  for (const p of HARD_REFUSALS) if (hay.includes(p)) return { allow: false, reason: SAFETY_REASON };
  for (const p of MANIPULATIVE) if (hay.includes(p)) return { allow: false, reason: SAFETY_REASON };
  return { allow: true };
}
