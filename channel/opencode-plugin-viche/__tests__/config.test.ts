/**
 * Tests for loadConfig — covers file loading, env var overrides, defaults,
 * validation, and precedence rules.
 *
 * Uses real temp directories for file-based cases so we exercise actual fs
 * reads. Env vars are saved/restored around every test.
 */

import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadConfig, isValidToken } from "../config.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const ENV_KEYS = [
  "VICHE_REGISTRY_URL",
  "VICHE_AGENT_NAME",
  "VICHE_CAPABILITIES",
  "VICHE_DESCRIPTION",
  "VICHE_REGISTRY_TOKEN",
] as const;

type SavedEnv = Record<(typeof ENV_KEYS)[number], string | undefined>;

/** Create a temp projectDir, optionally writing .opencode/viche.json. */
function makeTempDir(config?: unknown): string {
  const dir = join(
    tmpdir(),
    `opencode-plugin-viche-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  mkdirSync(dir, { recursive: true });
  if (config !== undefined) {
    mkdirSync(join(dir, ".opencode"), { recursive: true });
    writeFileSync(join(dir, ".opencode", "viche.json"), JSON.stringify(config));
  }
  return dir;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe("loadConfig", () => {
  let savedEnv: SavedEnv;
  let tempDir: string | undefined;

  beforeEach(() => {
    savedEnv = {} as SavedEnv;
    for (const key of ENV_KEYS) {
      savedEnv[key] = process.env[key];
      delete process.env[key];
    }
    tempDir = undefined;
  });

  afterEach(() => {
    for (const key of ENV_KEYS) {
      if (savedEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = savedEnv[key];
      }
    }
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  // ── 1. Pure defaults ───────────────────────────────────────────────────────

  it("returns defaults when there is no config file and no env vars", () => {
    tempDir = makeTempDir(); // no viche.json
    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://localhost:4000");
    expect(cfg.capabilities).toEqual(["coding"]);
    expect(cfg.agentName).toBe("opencode");
    expect(cfg.description).toBe("OpenCode AI coding assistant");
    // Registries should be auto-generated: a single-element array with a UUID.
    expect(Array.isArray(cfg.registries)).toBe(true);
    expect(cfg.registries).toHaveLength(1);
    expect(typeof cfg.registries![0]).toBe("string");
    expect(cfg.registries![0].length).toBeGreaterThan(0);
  });

  // ── 2. File loading ────────────────────────────────────────────────────────

  it("reads all values from .opencode/viche.json", () => {
    tempDir = makeTempDir({
      registryUrl: "http://viche.example.com",
      capabilities: ["code-review", "translation"],
      agentName: "my-agent",
      description: "A test agent",
    });

    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://viche.example.com");
    expect(cfg.capabilities).toEqual(["code-review", "translation"]);
    expect(cfg.agentName).toBe("my-agent");
    expect(cfg.description).toBe("A test agent");
  });

  // ── 3. Env var override ────────────────────────────────────────────────────

  it("env vars override file values when both are set", () => {
    tempDir = makeTempDir({
      registryUrl: "http://from-file.example.com",
      capabilities: ["from-file"],
      agentName: "file-agent",
      description: "from file",
    });
    process.env.VICHE_REGISTRY_URL = "http://from-env.example.com";
    process.env.VICHE_CAPABILITIES = "from-env,another";
    process.env.VICHE_AGENT_NAME = "env-agent";
    process.env.VICHE_DESCRIPTION = "from env";

    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://from-env.example.com");
    expect(cfg.capabilities).toEqual(["from-env", "another"]);
    expect(cfg.agentName).toBe("env-agent");
    expect(cfg.description).toBe("from env");
  });

  // ── 4. VICHE_CAPABILITIES comma-splitting ──────────────────────────────────

  it("splits VICHE_CAPABILITIES on commas and trims whitespace", () => {
    tempDir = makeTempDir();
    process.env.VICHE_CAPABILITIES = "coding,research,testing";

    const cfg = loadConfig(tempDir);

    expect(cfg.capabilities).toEqual(["coding", "research", "testing"]);
  });

  // ── 5. Empty capabilities fall back to default ─────────────────────────────

  it("falls back to default capabilities when file has an empty array", () => {
    tempDir = makeTempDir({ capabilities: [] });

    const cfg = loadConfig(tempDir);

    expect(cfg.capabilities).toEqual(["coding"]);
  });

  // ── 6. Invalid registryUrl type falls back to default ─────────────────────

  it("falls back to default registryUrl when file value is not a string", () => {
    tempDir = makeTempDir({ registryUrl: 42 });

    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://localhost:4000");
  });

  // ── 7. Full precedence: env > file > defaults ──────────────────────────────

  it("env vars take full precedence: env > file > defaults", () => {
    tempDir = makeTempDir({
      registryUrl: "http://file.example.com",
      capabilities: ["file-cap"],
      agentName: "file-agent",
      description: "from file",
    });
    process.env.VICHE_REGISTRY_URL = "http://env.example.com";
    process.env.VICHE_AGENT_NAME = "env-agent";
    process.env.VICHE_CAPABILITIES = "env-cap";
    process.env.VICHE_DESCRIPTION = "from env";

    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://env.example.com");
    expect(cfg.capabilities).toEqual(["env-cap"]);
    expect(cfg.agentName).toBe("env-agent");
    expect(cfg.description).toBe("from env");
  });

  // ── 8. Graceful on missing file ────────────────────────────────────────────

  it("does not throw when .opencode/viche.json is missing", () => {
    tempDir = makeTempDir(); // directory exists, no viche.json inside

    expect(() => loadConfig(tempDir!)).not.toThrow();
    expect(loadConfig(tempDir!).registryUrl).toBe("http://localhost:4000");
  });

  // ── 9. Graceful on invalid JSON ────────────────────────────────────────────

  it("falls back to defaults when .opencode/viche.json contains invalid JSON", () => {
    const dir = join(
      tmpdir(),
      `opencode-plugin-viche-invalid-${Date.now()}`
    );
    mkdirSync(join(dir, ".opencode"), { recursive: true });
    writeFileSync(join(dir, ".opencode", "viche.json"), "{ not valid json }}}");
    tempDir = dir;

    const cfg = loadConfig(tempDir);

    expect(cfg.registryUrl).toBe("http://localhost:4000");
    expect(cfg.capabilities).toEqual(["coding"]);
  });

  // ── 10. Default agentName and description ─────────────────────────────────

  it("uses 'opencode' as default agentName and 'OpenCode AI coding assistant' as default description", () => {
    tempDir = makeTempDir();

    const cfg = loadConfig(tempDir);

    expect(cfg.agentName).toBe("opencode");
    expect(cfg.description).toBe("OpenCode AI coding assistant");
  });

  // ── 11. VICHE_REGISTRY_TOKEN env var is parsed as comma-separated tokens ──

  it("parses VICHE_REGISTRY_TOKEN as comma-separated registries", () => {
    tempDir = makeTempDir();
    process.env.VICHE_REGISTRY_TOKEN = "token-a, token-b , token-c";

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["token-a", "token-b", "token-c"]);
  });

  it("handles a single VICHE_REGISTRY_TOKEN without commas", () => {
    tempDir = makeTempDir();
    process.env.VICHE_REGISTRY_TOKEN = "solo-token";

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["solo-token"]);
  });

  // ── 12. File: registries array ────────────────────────────────────────────

  it("reads registries array from .opencode/viche.json", () => {
    tempDir = makeTempDir({
      registries: ["reg-one", "reg-two"],
    });

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["reg-one", "reg-two"]);
  });

  // ── 13. Backwards compat: legacy registryToken string in file ─────────────

  it("converts legacy registryToken string in file to single-element registries array", () => {
    tempDir = makeTempDir({
      registryToken: "legacy-token",
    });

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["legacy-token"]);
  });

  // ── 14. Env var takes precedence over file registries ─────────────────────

  it("VICHE_REGISTRY_TOKEN env var overrides file registries", () => {
    tempDir = makeTempDir({
      registries: ["file-token"],
    });
    process.env.VICHE_REGISTRY_TOKEN = "env-token-1,env-token-2";

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["env-token-1", "env-token-2"]);
  });

  // ── 15. Auto-generation persists registries key (not registryToken) ───────

  it("auto-generates a UUID registry token and persists it as registries array in viche.json", () => {
    tempDir = makeTempDir(); // no viche.json

    const cfg = loadConfig(tempDir);

    // Token should be a non-empty string.
    expect(cfg.registries).toHaveLength(1);
    const token = cfg.registries![0]!;
    expect(typeof token).toBe("string");
    expect(token.length).toBeGreaterThan(0);

    // Subsequent call should reuse the same token.
    const cfg2 = loadConfig(tempDir);
    expect(cfg2.registries).toEqual([token]);
  });
});

// ---------------------------------------------------------------------------
// isValidToken
// ---------------------------------------------------------------------------

describe("isValidToken", () => {
  it("accepts valid alphanumeric tokens of at least 4 chars", () => {
    expect(isValidToken("abcd")).toBe(true);
    expect(isValidToken("ABCD")).toBe(true);
    expect(isValidToken("1234")).toBe(true);
    expect(isValidToken("team-x")).toBe(true);
    expect(isValidToken("my.token")).toBe(true);
    expect(isValidToken("my_token_123")).toBe(true);
  });

  it("accepts a UUID (auto-generated tokens are always valid)", () => {
    expect(isValidToken("550e8400-e29b-41d4-a716-446655440000")).toBe(true);
  });

  it("accepts a token exactly at the minimum length (4 chars)", () => {
    expect(isValidToken("abcd")).toBe(true);
  });

  it("accepts a token exactly at the maximum length (256 chars)", () => {
    expect(isValidToken("a".repeat(256))).toBe(true);
  });

  it("rejects a token that is too short (< 4 chars)", () => {
    expect(isValidToken("abc")).toBe(false);
    expect(isValidToken("")).toBe(false);
  });

  it("rejects a token that is too long (> 256 chars)", () => {
    expect(isValidToken("a".repeat(257))).toBe(false);
  });

  it("rejects tokens with spaces", () => {
    expect(isValidToken("bad token")).toBe(false);
    expect(isValidToken("bad token!")).toBe(false);
  });

  it("rejects tokens with special characters not in the allowed set", () => {
    expect(isValidToken("bad!token")).toBe(false);
    expect(isValidToken("bad@token")).toBe(false);
    expect(isValidToken("bad#token")).toBe(false);
    expect(isValidToken("bad/token")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Invalid token filtering in loadConfig
// ---------------------------------------------------------------------------

describe("loadConfig — invalid token filtering", () => {
  let savedEnv: Record<string, string | undefined>;
  let tempDir: string | undefined;

  const ENV_KEYS_FILTER = ["VICHE_REGISTRY_TOKEN"] as const;

  beforeEach(() => {
    savedEnv = {};
    for (const key of ENV_KEYS_FILTER) {
      savedEnv[key] = process.env[key];
      delete process.env[key];
    }
    tempDir = undefined;
  });

  afterEach(() => {
    for (const key of ENV_KEYS_FILTER) {
      if (savedEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = savedEnv[key];
      }
    }
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  it("filters out invalid tokens from VICHE_REGISTRY_TOKEN env var and falls back to auto-generate", () => {
    tempDir = makeTempDir();
    // "bad token!" contains a space — invalid
    process.env.VICHE_REGISTRY_TOKEN = "bad token!";

    const cfg = loadConfig(tempDir);

    // Invalid token filtered → falls through to auto-generate
    expect(cfg.registries).toHaveLength(1);
    // Auto-generated UUID is always valid
    expect(isValidToken(cfg.registries![0]!)).toBe(true);
  });

  it("keeps only valid tokens from a comma-separated VICHE_REGISTRY_TOKEN", () => {
    tempDir = makeTempDir();
    process.env.VICHE_REGISTRY_TOKEN = "valid-token,bad token!,another-valid";

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["valid-token", "another-valid"]);
  });

  it("filters out invalid tokens from file registries array", () => {
    tempDir = makeTempDir({ registries: ["good-token", "bad token!", "another-good"] });

    const cfg = loadConfig(tempDir);

    expect(cfg.registries).toEqual(["good-token", "another-good"]);
  });

  it("filters out invalid legacy registryToken from file and falls back to auto-generate", () => {
    tempDir = makeTempDir({ registryToken: "bad token!" });

    const cfg = loadConfig(tempDir);

    // Falls through to auto-generate
    expect(cfg.registries).toHaveLength(1);
    expect(isValidToken(cfg.registries![0]!)).toBe(true);
  });
});
