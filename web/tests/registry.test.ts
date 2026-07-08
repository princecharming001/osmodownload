// Signed config registry — round-trips, tamper-evident, reflects flags/models.

import { afterEach, describe, expect, it } from "vitest";
import { buildRegistry, signRegistry, verifyRegistry, registryPublicX } from "@/lib/config/registry";
import { GET as registryRoute } from "@/app/api/config/registry/route";

afterEach(() => { delete process.env.OSMO_FLAGS; delete process.env.OSMO_MODEL_SUGGEST; delete process.env.OSMO_ALLOWED_MODELS; });

describe("config registry", () => {
  it("signs and verifies a round-trip", async () => {
    const signed = signRegistry(buildRegistry(1000));
    const reg = verifyRegistry(signed);
    expect(reg).not.toBeNull();
    expect(reg!.updatedAt).toBe(1000);
    expect(reg!.models.suggest).toBeTruthy();
  });

  it("rejects a tampered payload", () => {
    const signed = signRegistry(buildRegistry());
    const tampered = { ...signed, registry: Buffer.from(JSON.stringify({ v: 1, flags: { aiDrafting: false } })).toString("base64url") };
    expect(verifyRegistry(tampered)).toBeNull();
  });

  it("carries the current flags (kill-switch is signed)", () => {
    process.env.OSMO_FLAGS = '{"aiDrafting":false}';
    const reg = verifyRegistry(signRegistry(buildRegistry()));
    expect(reg!.flags.aiDrafting).toBe(false);
  });

  it("only allows per-task models within the server allowlist", () => {
    process.env.OSMO_ALLOWED_MODELS = "claude-sonnet-5,claude-opus-4-8";
    process.env.OSMO_MODEL_SUGGEST = "claude-opus-4-8";
    const okReg = verifyRegistry(signRegistry(buildRegistry()));
    expect(okReg!.models.suggest).toBe("claude-opus-4-8");

    process.env.OSMO_MODEL_SUGGEST = "gpt-4o"; // not allowed → falls back to default
    const reg2 = verifyRegistry(signRegistry(buildRegistry()));
    expect(reg2!.models.suggest).not.toBe("gpt-4o");
  });

  it("the route returns a verifiable signed registry", async () => {
    const signed = await (await registryRoute()).json();
    expect(verifyRegistry(signed, registryPublicX())).not.toBeNull();
  });
});
