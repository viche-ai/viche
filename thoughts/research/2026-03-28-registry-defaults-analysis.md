---
date: 2026-03-28T12:00:00+02:00
researcher: mnemosyne
git_commit: 0f0da056a698d1ca685f218843a34903a4b1d9e4
branch: main
repository: viche-actual
topic: "Registry defaults behavior across OpenClaw, OpenCode, and server"
scope: channel/openclaw-plugin-viche/, channel/opencode-plugin-viche/, lib/viche/agents.ex
query_type: explain
tags: [research, registry, plugins, configuration]
status: complete
confidence: high
sources_scanned:
  files: 6
  thoughts_docs: 1
---

# Research: Registry Defaults Behavior

**Date**: 2026-03-28
**Commit**: 0f0da056a698d1ca685f218843a34903a4b1d9e4
**Branch**: main
**Confidence**: high - All code paths verified with exact line citations

## Query
How does the "global" registry default behavior work across OpenClaw plugin, OpenCode plugin, and the server-side `Viche.Agents.register_agent/1`?

## Summary
The `"global"` registry default is a **server-side guarantee** applied in `Viche.Agents.normalize_and_validate_registries/1` when no registries are provided. OpenClaw plugin may omit registries entirely (triggering server default), while OpenCode plugin always auto-generates a UUID token if none configured (bypassing the server default).

## Key Entry Points

| File | Symbol | Purpose |
|------|--------|---------|
| `channel/openclaw-plugin-viche/types.ts:211-230` | `VicheConfigSchema.safeParse` | Resolves registries from config |
| `channel/openclaw-plugin-viche/service.ts:338-347` | `connectAndJoin` callback | Joins registry channels via WebSocket |
| `channel/opencode-plugin-viche/config.ts:141-182` | `pickRegistries()` | Resolves registries from env/file |
| `channel/opencode-plugin-viche/config.ts:228-248` | `loadConfig()` | Auto-generates UUID if no registries |
| `channel/opencode-plugin-viche/service.ts:130-140` | `connectWebSocket` callback | Joins registry channels via WebSocket |
| `lib/viche/agents.ex:417-428` | `normalize_and_validate_registries/1` | Server-side default to `["global"]` |

## Architecture & Flow

### Data Flow
```
OpenClaw plugin
  openclaw.json config
      → VicheConfigSchema.safeParse()     [types.ts:211]
          registries array    → config.registries (if present)
          registryToken str   → config.registries = [token] (legacy fallback)
          neither             → config.registries = undefined
      → POST /registry/register           [service.ts:48]
          body.registries = config.registries (only if non-empty)
          if omitted          → server receives no registries key

OpenCode plugin
  VICHE_REGISTRY_TOKEN env var
  .opencode/viche.json (registries[] or legacy registryToken)
  auto-generate UUID + persist if none found
      → pickRegistries()                  [config.ts:141]
      → always non-undefined after loadConfig() [config.ts:231-248]
      → POST /registry/register           [service.ts:51]
          body.registries = config.registries (always non-empty)

Server: Viche.Agents.register_agent/1
  Map.get(attrs, :registries)             [agents.ex:154]
      → normalize_and_validate_registries/1
          nil  → ["global"]               [agents.ex:419]
          []   → ["global"]               [agents.ex:420]
          [...] → [...] (validated)       [agents.ex:422-425]
```

## Detailed Code Analysis

### 1. OpenClaw Plugin - Config Resolution

**File**: `channel/openclaw-plugin-viche/types.ts:211-230`

```typescript
const normalized: VicheConfig = {
  registryUrl:
    typeof raw.registryUrl === "string"
      ? raw.registryUrl
      : CONFIG_DEFAULTS.registryUrl,
  capabilities: Array.isArray(raw.capabilities)
    ? (raw.capabilities as string[])
    : CONFIG_DEFAULTS.capabilities,
};

// Only assign optional string properties when present to satisfy exactOptionalPropertyTypes.
if (typeof raw.agentName === "string") normalized.agentName = raw.agentName;
if (typeof raw.description === "string") normalized.description = raw.description;

// Resolve registries: prefer `registries` array; fall back to legacy `registryToken` string.
if (Array.isArray(raw.registries) && raw.registries.length > 0) {
  normalized.registries = raw.registries as string[];
} else if (typeof raw.registryToken === "string" && raw.registryToken.length > 0) {
  normalized.registries = [raw.registryToken];
}
```

**Precedence order**:
1. `registries` array from `openclaw.json` config (line 226-227)
2. Legacy `registryToken` string, converted to single-element array (line 228-229)
3. If neither present → `normalized.registries` remains `undefined`

### 2. OpenClaw Plugin - WebSocket Registry Channel Join

**File**: `channel/openclaw-plugin-viche/service.ts:338-347`

```typescript
.receive("ok", () => {
  logger.info(
    `Viche: registered as ${agentId}, connected via WebSocket`,
  );

  for (const token of config.registries ?? []) {
    const registryChannel = socket!.channel(`registry:${token}`, {});
    registryChannel
      .join()
      .receive("error", (resp: unknown) => {
        logger.warn(
          `Viche: registry channel join failed for ${token}: ${JSON.stringify(resp)}`
        );
      });
  }

  resolve();
})
```

The `?? []` nullish coalescing means: if `config.registries` is `undefined`, the loop body never executes — **no `registry:*` channels are joined client-side when no registries are configured**.

### 3. OpenCode Plugin - Config Resolution

**File**: `channel/opencode-plugin-viche/config.ts:141-182`

```typescript
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
```

**Precedence order**:
1. `VICHE_REGISTRY_TOKEN` env var (comma-separated) (line 145-153)
2. `registries` array from `.opencode/viche.json` (line 155-165)
3. Legacy `registryToken` string from `.opencode/viche.json` (line 167-179)
4. `undefined` if none of the above yield valid tokens (line 181)

### 4. OpenCode Plugin - Auto-Generation

**File**: `channel/opencode-plugin-viche/config.ts:228-248`

```typescript
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
```

**Key behavior**: OpenCode **always** produces a non-undefined `registries`. If `pickRegistries()` returns `undefined`, a UUID is auto-generated and persisted.

### 5. OpenCode Plugin - WebSocket Registry Channel Join

**File**: `channel/opencode-plugin-viche/service.ts:130-140`

```typescript
.receive("ok", () => {
  for (const token of config.registries ?? []) {
    const registryChannel = socket.channel(`registry:${token}`, {});
    registryChannel
      .join()
      .receive("error", (resp: unknown) => {
        process.stderr.write(
          `Viche: registry channel join failed for ${token}: ${JSON.stringify(resp)}\n`
        );
      });
  }
  resolve({ socket, channel });
})
```

Same pattern as OpenClaw, but since OpenCode always resolves a non-empty `registries` (via auto-generation), this loop always executes at least once.

### 6. Server-Side Default

**File**: `lib/viche/agents.ex:417-428`

```elixir
@spec normalize_and_validate_registries(term()) ::
        {:ok, [String.t()]} | {:error, :invalid_registry_token}
defp normalize_and_validate_registries(nil), do: {:ok, ["global"]}
defp normalize_and_validate_registries([]), do: {:ok, ["global"]}

defp normalize_and_validate_registries(registries) when is_list(registries) do
  if Enum.all?(registries, &valid_token?/1),
    do: {:ok, registries},
    else: {:error, :invalid_registry_token}
end

defp normalize_and_validate_registries(_), do: {:error, :invalid_registry_token}
```

**The `"global"` default is applied in exactly two cases**:
- `nil` is passed (registries key absent from request) → line 419
- Empty list `[]` is passed → line 420

Any non-empty list of valid tokens passes through as-is (line 422-425).

## Behavioral Comparison

| Aspect | OpenClaw | OpenCode |
|--------|----------|----------|
| **No config provided** | `config.registries = undefined` → omitted from POST body → **server defaults to `["global"]`** | `config.registries = [auto-generated-uuid]` → sent in POST body → **server uses the UUID, NOT `"global"`** |
| **Registry channel subscriptions** | Only joins `registry:{token}` channels if `config.registries` is non-empty | Always joins `registry:{token}` channels (at least the auto-generated one) |
| **`"global"` as default** | Yes — via server fallback | No — always sends an explicit (auto-generated) token |

## Gaps Identified

| Gap | Search Terms Used | Directories Searched |
|-----|-------------------|---------------------|
| No explicit "global" default in OpenCode plugin | "global", "default", "registry" | `channel/opencode-plugin-viche/` |
| No documentation of this behavioral difference | "global", "default", "registry" | `docs/`, `README.md` |

## Evidence Index

### Code Files
- `channel/openclaw-plugin-viche/types.ts:211-230` - Config normalization with registries resolution
- `channel/openclaw-plugin-viche/service.ts:338-347` - WebSocket registry channel join
- `channel/opencode-plugin-viche/config.ts:141-182` - `pickRegistries()` function
- `channel/opencode-plugin-viche/config.ts:228-248` - Auto-generation and persistence
- `channel/opencode-plugin-viche/service.ts:130-140` - WebSocket registry channel join
- `lib/viche/agents.ex:417-428` - Server-side `normalize_and_validate_registries/1`

### Documentation
- `thoughts/research/2026-03-25-private-registries-architecture.md` - Prior research on private registries

## Related Research

- `thoughts/research/2026-03-25-private-registries-architecture.md` - Architecture for private registries feature

---

## Handoff Inputs

**If implementation needed** (for @vulkanus):
- OpenClaw config resolution: `channel/openclaw-plugin-viche/types.ts:225-230`
- OpenCode config resolution: `channel/opencode-plugin-viche/config.ts:228-248`
- Server default: `lib/viche/agents.ex:419-420`
- Pattern to follow: OpenCode's auto-generation pattern at `config.ts:231-248`
