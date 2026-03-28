/**
 * Config loader for opencode-plugin-viche.
 *
 * Precedence (highest → lowest):
 *   1. Environment variables  (VICHE_REGISTRY_URL, VICHE_AGENT_NAME,
 *                               VICHE_CAPABILITIES, VICHE_DESCRIPTION)
 *   2. File: <projectDir>/.opencode/viche.json
 *   3. Built-in defaults
 *
 * The config file is optional — a missing or malformed file is silently
 * ignored and falls back to defaults.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { VicheConfig } from "./types.js";

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

const DEFAULT_REGISTRY_URL = "http://localhost:4000";
const DEFAULT_CAPABILITIES = ["coding"] as const;

// ---------------------------------------------------------------------------
// Raw file shape
// ---------------------------------------------------------------------------

/** Shape of the JSON we accept from .opencode/viche.json. */
type RawFileConfig = {
  registryUrl?: unknown;
  capabilities?: unknown;
  agentName?: unknown;
  description?: unknown;
  registryToken?: unknown;
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Load and parse .opencode/viche.json, returning an empty object on any
 * error (missing file, bad permissions, invalid JSON, non-object root).
 */
function loadFileConfig(projectDir: string): RawFileConfig {
  const configPath = join(projectDir, ".opencode", "viche.json");
  try {
    const raw = readFileSync(configPath, "utf-8");
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return {};
    }
    return parsed as RawFileConfig;
  } catch {
    return {};
  }
}

/**
 * Return the first non-blank string among `envVal`, `fileVal`, and
 * `fallback`, trimming each candidate before the emptiness check.
 */
function pickNonBlankString(
  envVal: string | undefined,
  fileVal: unknown,
  fallback: string
): string {
  if (typeof envVal === "string" && envVal.trim().length > 0) {
    return envVal.trim();
  }
  if (typeof fileVal === "string" && fileVal.trim().length > 0) {
    return fileVal.trim();
  }
  return fallback;
}

/**
 * Resolve a capabilities array from env var → file → defaults.
 *
 * `VICHE_CAPABILITIES` is a comma-separated string; each value is trimmed
 * and empty segments are dropped.
 */
function pickCapabilities(
  envVal: string | undefined,
  fileVal: unknown,
  fallback: readonly string[]
): string[] {
  if (typeof envVal === "string" && envVal.trim().length > 0) {
    const parsed = envVal
      .split(",")
      .map((c) => c.trim().toLowerCase())
      .filter(Boolean);
    if (parsed.length > 0) return parsed;
  }
  if (Array.isArray(fileVal)) {
    const filtered = (fileVal as unknown[])
      .map((c) => (typeof c === "string" ? c.trim().toLowerCase() : ""))
      .filter(Boolean);
    if (filtered.length > 0) return filtered;
  }
  return [...fallback];
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Build a `VicheConfig` for the given project directory.
 *
 * Registry token precedence (highest → lowest):
 *   1. `VICHE_REGISTRY_TOKEN` env var
 *   2. `registryToken` field in .opencode/viche.json
 *   3. Auto-generate a UUID, persist it to .opencode/viche.json, and use it
 *
 * @param projectDir  Absolute path to the OpenCode project root.
 */
export function loadConfig(projectDir: string): VicheConfig {
  const fileConfig = loadFileConfig(projectDir);

  const registryUrl = pickNonBlankString(
    process.env.VICHE_REGISTRY_URL,
    fileConfig.registryUrl,
    DEFAULT_REGISTRY_URL
  );

  const capabilities = pickCapabilities(
    process.env.VICHE_CAPABILITIES,
    fileConfig.capabilities,
    DEFAULT_CAPABILITIES
  );

  const agentName =
    pickNonBlankString(
      process.env.VICHE_AGENT_NAME,
      fileConfig.agentName,
      ""
    ) || undefined;

  const description =
    pickNonBlankString(
      process.env.VICHE_DESCRIPTION,
      fileConfig.description,
      ""
    ) || undefined;

  // Registry token: env var → file → auto-generate + persist
  let registryToken: string | undefined;
  const envToken = process.env.VICHE_REGISTRY_TOKEN;
  if (typeof envToken === "string" && envToken.trim().length > 0) {
    registryToken = envToken.trim();
  } else if (
    typeof fileConfig.registryToken === "string" &&
    fileConfig.registryToken.trim().length > 0
  ) {
    registryToken = fileConfig.registryToken.trim();
  } else {
    // Auto-generate and persist so subsequent runs reuse the same token.
    registryToken = crypto.randomUUID();
    const opencodeDir = join(projectDir, ".opencode");
    const configPath = join(opencodeDir, "viche.json");
    try {
      mkdirSync(opencodeDir, { recursive: true });
      // Merge with existing file content to avoid overwriting other fields.
      const merged = { ...fileConfig, registryToken };
      writeFileSync(configPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    } catch {
      // Persistence failure is non-fatal — we still return the generated token
      // for this run; a new one will be generated next time.
    }
  }

  const config: VicheConfig = { registryUrl, capabilities };
  if (agentName !== undefined) config.agentName = agentName;
  if (description !== undefined) config.description = description;
  if (registryToken !== undefined) config.registryToken = registryToken;

  return config;
}
