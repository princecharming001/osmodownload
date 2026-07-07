// Pure fact extraction from web search results — unit-testable, no I/O.
// The app's dossier LLM is the synthesis point; this layer just picks the
// sentences worth synthesizing and keeps each one attached to its source.

import type { ExaResult } from "./exa";

export interface WebFact {
  text: string;
  url: string;
}

/** Sentences 30–220 chars that actually mention the person (first or last
    name), deduped, LinkedIn pages dropped (redundant with the profile). The
    first sentence of the top result is always kept — it's usually the "who
    they are" line even when the name is only in the page title. */
export function extractFacts(results: ExaResult[], personName: string, max = 6): WebFact[] {
  const nameTokens = personName.toLowerCase().split(/\s+/).filter((t) => t.length > 1);
  const seen = new Set<string>();
  const out: WebFact[] = [];
  for (const [resultIndex, r] of results.entries()) {
    if (/linkedin\.com/i.test(r.url)) continue;
    const sentences = r.text
      .split(/(?<=[.!?])\s+/)
      .map((s) => s.replace(/\s+/g, " ").trim());
    for (const [sentenceIndex, s] of sentences.entries()) {
      if (out.length >= max) return out;
      if (s.length < 30 || s.length > 220) continue;
      const lower = s.toLowerCase();
      const mentionsName = nameTokens.some((t) => lower.includes(t));
      const isLede = resultIndex === 0 && sentenceIndex === 0;
      if (!mentionsName && !isLede) continue;
      const key = lower;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ text: s, url: r.url });
    }
  }
  return out;
}

/** Deterministic demo facts (keyless mode) — obviously fake domains. */
export function mockFacts(name: string): WebFact[] {
  const first = name.split(/\s+/)[0] || name;
  return [
    { text: `${first} was quoted in a piece on how small teams ship faster with fewer meetings.`,
      url: "https://news.example.com/small-teams-ship-faster" },
    { text: `${first} spoke on a panel about building consumer products people actually open twice.`,
      url: "https://events.example.com/consumer-products-panel" },
  ];
}
