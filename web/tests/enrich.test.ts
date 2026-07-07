import { describe, it, expect, beforeEach } from "vitest";
import { POST as register } from "@/app/api/device/register/route";
import { POST as enrich, resetRateLimitForTests } from "@/app/api/enrich/person/route";
import { resetStoreForTests } from "@/lib/connections/memoryStore";
import { extractFacts } from "@/lib/enrich/facts";

function req(path: string, token?: string, init?: RequestInit): Request {
  return new Request(`http://localhost:3000${path}`, {
    ...init,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(init?.body ? { "content-type": "application/json" } : {}),
      ...init?.headers,
    },
  });
}

async function registered(): Promise<{ token: string }> {
  const res = await register();
  const body = await res.json();
  return { token: body.deviceToken };
}

function enrichReq(token: string | undefined, body: unknown): Request {
  return req("/api/enrich/person", token, { method: "POST", body: JSON.stringify(body) });
}

describe("POST /api/enrich/person", () => {
  beforeEach(() => {
    resetStoreForTests();
    resetRateLimitForTests();
  });

  it("401 without a device token", async () => {
    const res = await enrich(enrichReq(undefined, { name: "Maya Render" }));
    expect(res.status).toBe(401);
  });

  it("400 without a name", async () => {
    const { token } = await registered();
    const res = await enrich(enrichReq(token, { linkedinHandle: "abc" }));
    expect(res.status).toBe(400);
  });

  it("keyless mode returns a deterministic mock bundle", async () => {
    const { token } = await registered();
    const a = await (await enrich(enrichReq(token, {
      name: "Maya Render", linkedinHandle: "att-123", hints: [] }))).json();
    resetRateLimitForTests();
    const b = await (await enrich(enrichReq(token, {
      name: "Maya Render", linkedinHandle: "att-123", hints: [] }))).json();

    expect(a.source).toBe("mock");
    expect(a.profile.name).toBe("Maya Render");     // real contact name kept
    expect(a.profile.headline.length).toBeGreaterThan(0);
    expect(a.profile.positions.length).toBeGreaterThan(0);
    expect(a.webFacts[0].text.length).toBeGreaterThan(0);
    expect(a.webFacts[0].url).toMatch(/^https:/);
    // Determinism: identical handle → identical profile.
    expect(b.profile).toEqual(a.profile);
  });

  it("no LinkedIn handle still yields a bundle (mock mode)", async () => {
    const { token } = await registered();
    const out = await (await enrich(enrichReq(token, { name: "Ada Only" }))).json();
    expect(out.source).toBe("mock");
    expect(out.profile).not.toBeNull();
  });

  it("429 after the per-device window is exhausted", async () => {
    const { token } = await registered();
    for (let i = 0; i < 10; i++) {
      const res = await enrich(enrichReq(token, { name: `Person ${i}` }));
      expect(res.status).toBe(200);
    }
    const blocked = await enrich(enrichReq(token, { name: "One Too Many" }));
    expect(blocked.status).toBe(429);
  });
});

describe("extractFacts", () => {
  const results = [
    { title: "Feature", url: "https://techsite.example/growth",
      text: "Maya Render leads growth at Reelio. The weather was nice. Render previously scaled two consumer apps past a million users without paid acquisition channels." },
    { title: "LinkedIn", url: "https://www.linkedin.com/in/maya",
      text: "Maya Render is on LinkedIn with 500+ connections and posts weekly." },
    { title: "Duplicate", url: "https://other.example/dup",
      text: "Maya Render leads growth at Reelio." },
  ];

  it("keeps name-bearing sentences with their source URLs", () => {
    const facts = extractFacts(results, "Maya Render");
    expect(facts[0]).toEqual({ text: "Maya Render leads growth at Reelio.", url: "https://techsite.example/growth" });
    expect(facts.some((f) => f.text.startsWith("Render previously scaled"))).toBe(true);
  });

  it("drops linkedin.com results, no-name sentences, and duplicates", () => {
    const facts = extractFacts(results, "Maya Render");
    expect(facts.some((f) => f.url.includes("linkedin.com"))).toBe(false);
    expect(facts.some((f) => f.text.includes("weather"))).toBe(false);
    expect(facts.filter((f) => f.text === "Maya Render leads growth at Reelio.").length).toBe(1);
  });

  it("always keeps the top result's lede even without the name", () => {
    const facts = extractFacts([
      { title: "Profile", url: "https://mag.example/a",
        text: "The company's head of growth joined after a decade in consumer social." },
    ], "Maya Render");
    expect(facts.length).toBe(1);
  });

  it("caps at max and enforces length bounds", () => {
    const many = Array.from({ length: 20 }, (_, i) => ({
      title: "t", url: `https://s${i}.example/x`,
      text: `Maya Render did notable thing number ${i} this year at a conference.`,
    }));
    expect(extractFacts(many, "Maya Render", 6).length).toBe(6);
    expect(extractFacts([{ title: "t", url: "https://s.example", text: "Maya wow." }], "Maya Render")).toEqual([]);
  });
});
