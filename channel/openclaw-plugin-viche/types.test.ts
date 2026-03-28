/**
 * Tests for VicheConfigSchema.safeParse — registry auto-generation behaviour.
 *
 * Key invariant: when no registries are configured, the plugin must NOT silently
 * join the "global" registry. It must auto-generate a private UUID token so the
 * server (which defaults nil/empty → "global") receives an explicit non-global token.
 */

import { describe, it, expect } from "bun:test";
import { VicheConfigSchema } from "./types.ts";

// UUID v4 regex — matches the shape produced by crypto.randomUUID()
const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

describe("VicheConfigSchema.safeParse — registry auto-generation", () => {
  it("auto-generates a private UUID token when config is undefined", () => {
    const result = VicheConfigSchema.safeParse(undefined);
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(Array.isArray(result.data.registries)).toBe(true);
    expect(result.data.registries!.length).toBe(1);
    const token = result.data.registries![0]!;
    expect(UUID_REGEX.test(token)).toBe(true);
    expect(token).not.toBe("global");
  });

  it("auto-generates a private UUID token when config is null", () => {
    const result = VicheConfigSchema.safeParse(null);
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(Array.isArray(result.data.registries)).toBe(true);
    expect(result.data.registries!.length).toBe(1);
    const token = result.data.registries![0]!;
    expect(UUID_REGEX.test(token)).toBe(true);
    expect(token).not.toBe("global");
  });

  it("auto-generates a private UUID token when config is empty object", () => {
    const result = VicheConfigSchema.safeParse({});
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(Array.isArray(result.data.registries)).toBe(true);
    expect(result.data.registries!.length).toBe(1);
    const token = result.data.registries![0]!;
    expect(UUID_REGEX.test(token)).toBe(true);
    expect(token).not.toBe("global");
  });

  it("auto-generates a different UUID on each safeParse call (not cached)", () => {
    const r1 = VicheConfigSchema.safeParse({});
    const r2 = VicheConfigSchema.safeParse({});
    expect(r1.success).toBe(true);
    expect(r2.success).toBe(true);
    if (!r1.success || !r2.success) return;

    // Each call generates a fresh UUID — tokens should differ
    expect(r1.data.registries![0]).not.toBe(r2.data.registries![0]);
  });

  it("respects explicit registries array — does NOT auto-generate", () => {
    const result = VicheConfigSchema.safeParse({ registries: ["my-team"] });
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(result.data.registries).toEqual(["my-team"]);
  });

  it("respects explicit registries: ['global'] — opts in to global", () => {
    const result = VicheConfigSchema.safeParse({ registries: ["global"] });
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(result.data.registries).toEqual(["global"]);
  });

  it("respects legacy registryToken — converts to single-element array, does NOT auto-generate", () => {
    const result = VicheConfigSchema.safeParse({ registryToken: "legacy-token" });
    expect(result.success).toBe(true);
    if (!result.success) return;

    expect(result.data.registries).toEqual(["legacy-token"]);
  });

  it("auto-generates UUID when registries is an empty array", () => {
    const result = VicheConfigSchema.safeParse({ registries: [] });
    expect(result.success).toBe(true);
    if (!result.success) return;

    const token = result.data.registries![0]!;
    expect(UUID_REGEX.test(token)).toBe(true);
    expect(token).not.toBe("global");
  });

  it("auto-generates UUID when registryToken is an empty string", () => {
    const result = VicheConfigSchema.safeParse({ registryToken: "" });
    expect(result.success).toBe(true);
    if (!result.success) return;

    const token = result.data.registries![0]!;
    expect(UUID_REGEX.test(token)).toBe(true);
    expect(token).not.toBe("global");
  });
});
