// Person-enrichment orchestrator: LinkedIn profile (Unipile) + public web
// context (Exa), merged into one wire bundle. No LLM here — the app's dossier
// completion is the synthesis point. Every degradation is a smaller bundle,
// never an error: no LinkedIn connection → web-only; stale handle (404) →
// web-only; no Exa key → linkedin-only; fully keyless → deterministic mock.

import { getUnipile, type UnipileUserProfile } from "../unipile/client";
import { getStore } from "../connections/memoryStore";
import { searchPerson, exaConfigured } from "./exa";
import { extractFacts, mockFacts, type WebFact } from "./facts";

export interface EnrichRequest {
  name: string;
  linkedinHandle: string | null;
  hints: string[];
}

export interface EnrichResponse {
  profile: UnipileUserProfile | null;
  webFacts: WebFact[];
  source: "linkedin" | "web" | "both" | "mock" | "none";
  fetchedAt: string;
}

export async function enrichPerson(deviceId: string, req: EnrichRequest): Promise<EnrichResponse> {
  const unipile = getUnipile();
  const fetchedAt = new Date().toISOString();

  // Keyless demo: the whole feature works offline, deterministically.
  if (unipile.mode === "mock") {
    const profile = await unipile.getUserProfile("mock", req.linkedinHandle ?? req.name);
    if (profile) profile.name = req.name;   // demo data, the user's real contact name
    return { profile, webFacts: mockFacts(req.name), source: "mock", fetchedAt };
  }

  let profile: UnipileUserProfile | null = null;
  let linkedinFailed = false;
  const accountId = getStore().connections(deviceId)
    .find((c) => c.platform === "linkedin" && c.status === "connected")?.id;
  if (accountId && req.linkedinHandle) {
    try {
      profile = await unipile.getUserProfile(accountId, req.linkedinHandle);
    } catch {
      linkedinFailed = true;   // upstream error ≠ "no profile"; web may still land
    }
  }

  let webFacts: WebFact[] = [];
  let webFailed = false;
  if (exaConfigured()) {
    // The profile sharpens the query for common names.
    const hints = [...req.hints, profile?.company ?? "", profile?.title ?? ""]
      .filter(Boolean).slice(0, 6);
    try {
      webFacts = extractFacts(await searchPerson(req.name, hints), req.name);
    } catch {
      webFailed = true;
    }
  }

  // Both paths configured AND both hard-failed → a real outage, not emptiness.
  if (linkedinFailed && (webFailed || !exaConfigured()) && !profile && webFacts.length === 0) {
    throw new Error("enrichment upstreams unavailable");
  }

  const source: EnrichResponse["source"] =
    profile && webFacts.length > 0 ? "both"
    : profile ? "linkedin"
    : webFacts.length > 0 ? "web"
    : "none";
  return { profile, webFacts, source, fetchedAt };
}
