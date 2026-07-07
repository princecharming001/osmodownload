// Exa web search for person enrichment. Ported from the proven wrapper in
// palo-outreach-app/lib/exa.js, trimmed to the one call this feature needs.
// Keyless → returns [] (LinkedIn-only degradation); the orchestrator decides
// when mock facts stand in.

export interface ExaResult {
  title: string;
  url: string;
  text: string;
}

export function exaConfigured(): boolean {
  return Boolean(process.env.EXA_API_KEY);
}

async function exaPost(body: Record<string, unknown>): Promise<{ results?: ExaResult[] }> {
  let lastError: Error | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch("https://api.exa.ai/search", {
      method: "POST",
      headers: {
        "x-api-key": process.env.EXA_API_KEY ?? "",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if (res.ok) return res.json() as Promise<{ results?: ExaResult[] }>;
    lastError = new Error(`exa search → ${res.status}`);
    // Retry only what retrying can fix.
    if (res.status !== 429 && res.status < 500) throw lastError;
    await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
  }
  throw lastError ?? new Error("exa search failed");
}

/** Public web results about a person. Hints (their company, the user's own
    notes) disambiguate common names. */
export async function searchPerson(name: string, hints: string[]): Promise<ExaResult[]> {
  if (!exaConfigured()) return [];
  const query = [`"${name}"`, ...hints.filter(Boolean)].join(" ").trim();
  const out = await exaPost({
    query,
    numResults: 5,
    type: "auto",
    contents: { text: { maxCharacters: 800 } },
  });
  return (out.results ?? []).filter((r) => r.url && r.text);
}
