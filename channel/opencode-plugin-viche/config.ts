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
  /** New multi-registry field (array of token strings). */
  registries?: unknown;
  /** Legacy single-token field — converted to `registries` array on load. */
  registryToken?: unknown;
};

// ---------------------------------------------------------------------------
// Token validation
// ---------------------------------------------------------------------------

const TOKEN_REGEX = /^[a-zA-Z0-9._-]+$/;

/**
 * Returns `true` if `token` satisfies the server's registry token format rules:
 * 4–256 characters, alphanumeric with `.`, `_`, and `-` only.
 *
 * Mirrors the server-side `Viche.Agents.valid_token?/1` rule.
 */
export function isValidToken(token: string): boolean {
  return token.length >= 4 && token.length <= 256 && TOKEN_REGEX.test(token);
}

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

/**
 * Warn to stderr about tokens that fail server-side format validation.
 */
function warnInvalidTokens(tokens: string[], source: string): void {
  for (const token of tokens) {
    if (!isValidToken(token)) {
      process.stderr.write(
        `Viche: ignoring invalid registry token from ${source} — token must be 4-256 chars, alphanumeric with . _ - (got: ${JSON.stringify(token)})\n`
      );
    }
  }
}

/**
 * Resolve a registries array from env var → file (registries array) → file (legacy registryToken).
 * Invalid tokens (not matching server format rules) are filtered out with a warning.
 */
function pickRegistries(
  envVal: string | undefined,
  fileConfig: RawFileConfig
): string[] | undefined {
  if (typeof envVal === "string" && envVal.trim().length > 0) {
    const candidates = envVal
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    warnInvalidTokens(candidates, "VICHE_REGISTRY_TOKEN env var");
    const parsed = candidates.filter(isValidToken);
    if (parsed.length > 0) return parsed;
  }

  if (
    Array.isArray(fileConfig.registries) &&
    (fileConfig.registries as unknown[]).every((r) => typeof r === "string")
  ) {
    const candidates = (fileConfig.registries as string[]).filter(
      (r) => r.trim().length > 0
    );
    warnInvalidTokens(candidates, "viche.json registries");
    const filtered = candidates.filter(isValidToken);
    if (filtered.length > 0) return filtered;
  }

  if (
    typeof fileConfig.registryToken === "string" &&
    fileConfig.registryToken.trim().length > 0
  ) {
    const candidate = fileConfig.registryToken.trim();
    if (!isValidToken(candidate)) {
      process.stderr.write(
        `Viche: ignoring invalid registry token from viche.json registryToken — token must be 4-256 chars, alphanumeric with . _ - (got: ${JSON.stringify(candidate)})\n`
      );
      return undefined;
    }
    return [candidate];
  }

  return undefined;
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
      "opencode"
    ) || undefined;

  const description =
    pickNonBlankString(
      process.env.VICHE_DESCRIPTION,
      fileConfig.description,
      "OpenCode AI coding assistant"
    ) || undefined;

  // Registries: env var (comma-separated) → file registries array → legacy file registryToken → auto-generate + persist
  let registries = pickRegistries(process.env.VICHE_REGISTRY_TOKEN, fileConfig);

  // 3. Auto-generate and persist so subsequent runs reuse the same token.
  if (registries === undefined) {
    const generated = crypto.randomUUID();
    registries = [generated];
    const opencodeDir = join(projectDir, ".opencode");
    const configPath = join(opencodeDir, "viche.json");
    try {
      mkdirSync(opencodeDir, { recursive: true });
      // Merge with existing file content to avoid overwriting other fields.
      // Write as `registries` array; drop legacy `registryToken` key.
      const { registryToken: _drop, ...rest } = fileConfig as Record<string, unknown>;
      void _drop;
      const merged = { ...rest, registries };
      writeFileSync(configPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
    } catch {
      // Persistence failure is non-fatal — we still return the generated token
      // for this run; a new one will be generated next time.
    }
  }

  const config: VicheConfig = { registryUrl, capabilities };
  if (agentName !== undefined) config.agentName = agentName;
  if (description !== undefined) config.description = description;
  if (registries !== undefined) config.registries = registries;

  return config;
}
