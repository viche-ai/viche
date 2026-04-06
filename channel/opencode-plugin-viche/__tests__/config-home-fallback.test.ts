/**
 * Tests for the home-directory fallback in loadConfig.
 *
 * When <projectDir>/.opencode/viche.json is absent, loadConfig should fall
 * back to ~/.opencode/viche.json.  Precedence remains:
 *   env vars > project viche.json > home viche.json > defaults
 *
 * Mock strategy:
 *   - `node:os` is mocked via mock.module so homedir() returns a temp dir we
 *     control per-test.
 *   - config.ts is loaded via a dynamic import AFTER the mock is registered,
 *     so the mocked homedir() is used inside the module.
 *   - Real temp directories are used for both project and home dirs.
 */

import { mock, describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ---------------------------------------------------------------------------
// node:os mock — must be registered BEFORE the dynamic import of config.js
// ---------------------------------------------------------------------------

/** Module-level variable; tests set this in beforeEach so homedir() returns it. */
let fakeHomeDir: string = tmpdir(); // safe default (no .opencode/viche.json there)

mock.module("node:os", () => ({
  homedir: () => fakeHomeDir,
  // Preserve tmpdir so any code that needs it still works.
  tmpdir,
}));

// Dynamic import AFTER mock so config.ts picks up the mocked node:os.
const { loadConfig } = await import("../config.js");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTempDir(config?: unknown): string {
  const dir = join(
    tmpdir(),
    `viche-home-fallback-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  mkdirSync(dir, { recursive: true });
  if (config !== undefined) {
    mkdirSync(join(dir, ".opencode"), { recursive: true });
    writeFileSync(
      join(dir, ".opencode", "viche.json"),
      JSON.stringify(config, null, 2) + "\n",
      "utf-8"
    );
  }
  return dir;
}

const ENV_KEYS = [
  "VICHE_REGISTRY_URL",
  "VICHE_AGENT_NAME",
  "VICHE_CAPABILITIES",
  "VICHE_DESCRIPTION",
  "VICHE_REGISTRY_TOKEN",
] as const;

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe("loadConfig — home directory fallback", () => {
  let tempDirs: string[] = [];
  let savedEnv: Record<string, string | undefined> = {};

  beforeEach(() => {
    tempDirs = [];
    savedEnv = {};
    for (const key of ENV_KEYS) {
      savedEnv[key] = process.env[key];
      delete process.env[key];
    }
    fakeHomeDir = tmpdir(); // reset to a dir that has no .opencode/viche.json
  });

  afterEach(() => {
    for (const key of ENV_KEYS) {
      if (savedEnv[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = savedEnv[key];
      }
    }
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs = [];
  });

  it("falls back to ~/.opencode/viche.json when project viche.json is absent", () => {
    const homeDir = makeTempDir({
      registryUrl: "http://home-viche:8888",
      registries: ["home-token"],
    });
    const projectDir = makeTempDir(); // no .opencode/viche.json
    tempDirs.push(homeDir, projectDir);

    fakeHomeDir = homeDir;

    const cfg = loadConfig(projectDir);

    expect(cfg.registryUrl).toBe("http://home-viche:8888");
    expect(cfg.registries).toEqual(["home-token"]);
  });

  // ── Precedence: project file wins over home file ──────────────────────────

  it("project .opencode/viche.json takes priority over ~/.opencode/viche.json", () => {
    const homeDir = makeTempDir({
      registryUrl: "http://home-viche:8888",
      registries: ["home-token"],
    });
    const projectDir = makeTempDir({
      registryUrl: "http://project-viche:7777",
      registries: ["project-token"],
    });
    tempDirs.push(homeDir, projectDir);

    fakeHomeDir = homeDir;

    const cfg = loadConfig(projectDir);

    expect(cfg.registryUrl).toBe("http://project-viche:7777");
    expect(cfg.registries).toEqual(["project-token"]);
  });

  // ── Precedence: env vars win over home file ───────────────────────────────

  it("env vars take priority over ~/.opencode/viche.json", () => {
    const homeDir = makeTempDir({
      registryUrl: "http://home-viche:8888",
      registries: ["home-token"],
    });
    const projectDir = makeTempDir(); // no project viche.json
    tempDirs.push(homeDir, projectDir);

    fakeHomeDir = homeDir;
    process.env.VICHE_REGISTRY_URL = "http://env-viche:6666";
    process.env.VICHE_REGISTRY_TOKEN = "env-token";

    const cfg = loadConfig(projectDir);

    expect(cfg.registryUrl).toBe("http://env-viche:6666");
    expect(cfg.registries).toEqual(["env-token"]);
  });

  // ── home file absent → still falls back to defaults ──────────────────────

  it("uses defaults when both project and home viche.json are absent", () => {
    const projectDir = makeTempDir(); // no project viche.json
    const homeDir = makeTempDir(); // no home viche.json either
    tempDirs.push(projectDir, homeDir);

    fakeHomeDir = homeDir;

    const cfg = loadConfig(projectDir);

    expect(cfg.registryUrl).toBe("http://localhost:4000");
    expect(cfg.capabilities).toEqual(["coding"]);
  });

  // ── auto-generation still writes to project dir, not home dir ─────────────
  //
  // When registries must be auto-generated (no env, no project file, no home
  // file with registries), the token must be persisted to the PROJECT dir.

  it("auto-generates registry token and persists to project dir, not home dir", () => {
    const projectDir = makeTempDir(); // no viche.json
    const homeDir = makeTempDir(); // no viche.json
    tempDirs.push(projectDir, homeDir);

    fakeHomeDir = homeDir;

    const cfg = loadConfig(projectDir);

    // Token is auto-generated and valid.
    expect(cfg.registries).toHaveLength(1);
    const token = cfg.registries![0]!;
    expect(typeof token).toBe("string");
    expect(token.length).toBeGreaterThan(0);

    // Persisted to project dir.
    const projectConfig = JSON.parse(
      readFileSync(join(projectDir, ".opencode", "viche.json"), "utf-8")
    ) as { registries?: string[] };
    expect(projectConfig.registries).toEqual([token]);

    // NOT written to home dir.
    expect(existsSync(join(homeDir, ".opencode", "viche.json"))).toBe(false);
  });
});
