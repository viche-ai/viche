# Session Handoff: Claude Code Plugin + Private Registry Discovery Fix

**Date**: April 3, 2026  
**Branch**: `feature/claude-code-plugin`  
**PR**: https://github.com/viche-ai/viche/pull/48  
**Issue**: https://github.com/viche-ai/viche/issues/44

---

## 1. Summary

This session worked on two parallel goals:

1. **Fix GitHub Issue #44** — `viche_discover` was ignoring private registries and always querying through the unscoped agent channel
2. **Create Claude Code plugin** — Build `channel/claude-code-plugin-viche/` as a proper marketplace-ready plugin with userConfig, SessionStart hooks, and the Viche network skill

**Current Status**:
- ✅ Plugin created with all 8 files
- ✅ Issue #44 fix implemented (registry channel routing)
- ✅ Quality gates pass (397 tests, 0 Credo, 0 Dialyzer)
- ✅ PR #48 open
- ✅ Previously unpushed follow-up commits are now pushed
- ✅ **E2E inbound message validation completed** (standalone MCP server + localhost Phoenix)

---

## 2. What Was Done

### Plugin Created: `channel/claude-code-plugin-viche/`

All 8 files created:

1. **`.claude-plugin/plugin.json`** — Plugin manifest
   - Declares `userConfig` fields: `registry_url`, `capabilities`, `agent_name`, `description`, `registries`
   - Binds channel to MCP server: `"channels": [{ "server": "viche" }]`
   - Marks `registries` as sensitive (private tokens)

2. **`.gitignore`** — Excludes build artifacts
   - `node_modules/`
   - `bun.lock`

3. **`.mcp.json`** — MCP server configuration
   - Maps `userConfig` → env vars (`VICHE_REGISTRY_URL`, `VICHE_CAPABILITIES`, etc.)
   - Runs `viche-server.ts` via Bun
   - Sets `NODE_PATH` to `${CLAUDE_PLUGIN_DATA}/node_modules`

4. **`hooks/hooks.json`** — SessionStart hook
   - Auto-runs `bun install` when `package.json` changes
   - Uses `diff` to detect changes and avoid redundant installs
   - Copies `package.json` to `${CLAUDE_PLUGIN_DATA}` and installs there

5. **`package.json`** — Dependencies
   - `@modelcontextprotocol/sdk` ^1.0.0
   - `phoenix` ^1.7.0

6. **`skills/viche/SKILL.md`** — Viche network skill
   - Ported from `.opencode/skills/viche/SKILL.md`
   - Documents inbound message handling, multi-turn conversations, tool reference
   - Explains private registry scoping

7. **`viche-server.ts`** — MCP server (406 lines)
   - Implements 3 tools: `viche_discover`, `viche_send`, `viche_reply`
   - Registers agent via HTTP POST `/registry/register` with retry (3 attempts, 2s backoff)
   - Connects to Phoenix Channel via WebSocket (`agent:{id}` + `registry:{token}` channels)
   - **Issue #44 fix**: Stores registry channels in `Map<string, PhoenixChannel>` and routes discovery through:
     1. Explicit token → that registry channel
     2. No token, registries configured → first registry channel
     3. No registries → agent channel (global/unscoped fallback)
   - Pushes inbound messages to Claude Code via `notifications/claude/channel`

8. **`README.md`** — Installation, usage, local testing docs
   - Marketplace install instructions (placeholder)
   - Local plugin directory usage with `--plugin-dir` and `--dangerously-load-development-channels`
   - Configuration reference
   - Private registry usage examples
   - Local development step-by-step (Phoenix server → bun install → launch Claude Code)
   - Troubleshooting section

### Issue #44 Fix (Private Registry Discovery)

**Root cause**: `viche_discover` always pushed through `activeChannel` (the `agent:{id}` channel) which has no `registry_token` in socket assigns. Registry channels were joined but references discarded.

**Fix** (in `viche-server.ts` lines 103, 166-178, 314-340):
- Store registry channels in `Map<string, PhoenixChannel>`
- Join `registry:{token}` channels after agent channel join succeeds
- Discovery routing logic:
  1. If `token` param provided and that registry channel exists → use it
  2. Else if any registry channels joined → use first one
  3. Else → use agent channel (global/unscoped fallback)

**Impact**: Discovery now respects private registries. Agents can discover peers within their team/project namespace.

### Channel Notification Fix

**Commit**: `5659336` (previously unpushed during session, now pushed)

**Problem**: `viche-server.ts` was sending invalid `channel` field in notification params:
```typescript
// INVALID (old code)
server.notification({
  method: "notifications/claude/channel",
  params: {
    channel: "viche",  // ❌ not a valid param
    content: "...",
    meta: { ... }
  }
})
```

**Fix**: Removed `channel` field, added `type` to meta:
```typescript
// VALID (new code)
server.notification({
  method: "notifications/claude/channel",
  params: {
    content: `[${displayType} from ${payload.from}] ${payload.body}`,
    meta: {
      message_id: payload.id,
      from: payload.from,
      type: messageType,  // ✅ added to meta
    }
  }
})
```

**Reason**: Per Claude Code channels-reference docs, only `content` and `meta` are valid params. The `source` attribute is set automatically from the server's configured name.

### Config Fallback Fix

**Commit**: `8b5f600` (previously unpushed during session, now pushed)

**Problem**: `.mcp.json` used `??` (nullish coalescing) for env var fallbacks:
```json
"VICHE_REGISTRY_URL": "${user_config.registry_url ?? 'http://localhost:4000'}"
```

When `userConfig` isn't configured, Claude Code plugin system resolves `${user_config.KEY}` to **empty string** (`""`), not `undefined`. The `??` operator treats `""` as defined, so fallbacks never triggered.

**Fix**: Changed all 5 env var lines to use `||` (logical OR):
```json
"VICHE_REGISTRY_URL": "${user_config.registry_url || 'http://localhost:4000'}"
```

**Affected vars**:
- `VICHE_REGISTRY_URL`
- `VICHE_AGENT_NAME`
- `VICHE_CAPABILITIES`
- `VICHE_DESCRIPTION`
- `VICHE_REGISTRY_TOKEN`

**Reason**: `||` treats empty string as falsy and falls back to defaults.

---

## 3. What's Working ✅

- **Plugin loads in Claude Code** — `viche MCP · ✔ connected` appears in `/plugin` → Installed tab
- **All 3 tools work**:
  - `viche_discover` → returns agent list
  - `viche_send` → sends messages
  - `viche_reply` → sends result messages
- **Channel registration** — when using `--dangerously-load-development-channels server:viche`, the banner "Listening for channel messages from: server:viche" appears
- **Inbound message delivery end-to-end** — task and result messages sent via HTTP are received over WebSocket and emitted as valid Claude channel notifications (`notifications/claude/channel` with `content` + `meta`)
- **Quality gates pass**:
  - 397 tests passing
  - 0 Credo issues
  - 0 Dialyzer warnings
- **PR #48 is open** and includes all related commits

---

## 4. What's NOT Working Yet ❌

### ⚠️ `--plugin-dir` does not register MCP servers from plugin `.mcp.json`

**New finding from real Claude Code E2E testing**:

- Launching with:
  ```bash
  claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche
  ```
  does **not** make the plugin-local `.mcp.json` server available.
- Claude Code error observed:
  - `server:viche · no MCP server configured with that name`

**What currently works**:
- Define the `viche` server in the repository root `.mcp.json` (or project-level MCP config), then run:
  ```bash
  claude --dangerously-load-development-channels server:viche
  ```

**Interpretation**:
- `--plugin-dir` appears to load plugin manifest/hook/skill assets, but not MCP server registration from plugin `.mcp.json` in this dev workflow.
- If both root `.mcp.json` and plugin config define a `viche` server, root config wins.

**Impact**:
- Not a blocker for validating channel behavior in development (root `.mcp.json` workaround is effective).
- Still needs follow-up investigation for expected `--plugin-dir` MCP behavior and marketplace/runtime parity.

---

## 5. Git State

**Branch**: `feature/claude-code-plugin`

**Remote**: `origin/feature/claude-code-plugin` includes all commits from this workstream

**Push status**:
- ✅ All previously local follow-up commits are pushed
- ✅ Branch and PR now reflect notification format and env fallback fixes

**PR**: https://github.com/viche-ai/viche/pull/48
- PR reflects the pushed follow-up fixes and updated E2E status in this handoff

**Files changed** (from first commit):
- Created: 8 files in `channel/claude-code-plugin-viche/`
- Modified: none (all new files)

---

## 6. Key Learnings (Claude Code Plugin System)

### 1. Channels require explicit opt-in

The `--channels` flag (allowlisted plugins) or `--dangerously-load-development-channels` (dev mode) is **required**. Without it:
- MCP server connects ✅
- Tools work ✅
- Channel notification listener is **never registered** ❌

**Symptom**: "Listening for channel messages from: server:viche" banner does NOT appear.

**Fix**: Always use `--dangerously-load-development-channels server:<name>` for local testing.

### 2. Channel notification format

**Correct format**:
```typescript
await mcp.notification({
  method: "notifications/claude/channel",
  params: {
    content: "message body",  // becomes <channel> tag body
    meta: { key: "value" },   // becomes tag attributes
  },
})
```

**Result in Claude Code session**:
```xml
<channel source="viche" key="value">message body</channel>
```

**Invalid fields**:
- ❌ `channel` — not a valid param (source is set automatically from server name)
- ❌ `type` as top-level param — must be in `meta` if needed

### 3. Server capabilities

Must declare experimental capability to register as a channel:
```typescript
const server = new Server(
  { name: "viche-channel", version: "1.0.0" },
  {
    capabilities: {
      experimental: { "claude/channel": {} },  // ✅ required
      tools: {},
    },
  }
);
```

### 4. userConfig env vars

When `${user_config.KEY}` isn't configured, Claude Code may either:
- Pass empty string (`""`)
- Leave the env var unset (inheriting parent env)

**Best practice**: Use `||` instead of `??` for fallbacks:
```json
"VICHE_REGISTRY_URL": "${user_config.registry_url || 'http://localhost:4000'}"
```

**Caveat**: If the parent shell has `VICHE_REGISTRY_URL=https://viche.ai` set, and userConfig is not configured, the MCP server may inherit the parent value instead of using the fallback. This needs testing.

### 5. Research preview

Custom channels aren't on the approved allowlist. Use `--dangerously-load-development-channels server:<name>` for local testing.

**Marketplace submission**: Once submitted, the channel will be allowlisted and users won't need the `--dangerously-load-development-channels` flag.

### 6. Plugin channels declaration

The `channels` field in `plugin.json` binds a channel to an MCP server:
```json
"channels": [{ "server": "viche" }]
```

This tells Claude Code: "When this plugin is installed, register the `viche` MCP server as a channel source."

---

## 7. Next Steps (Priority Order)

### 1. Submit Claude Code plugin to marketplace ✅ next primary milestone

**Submission URL**: https://claude.ai/settings/plugins/submit or https://platform.claude.com/plugins/submit

**Prerequisites**:
- ✅ Plugin loads without errors
- ✅ All tools work
- ✅ Inbound messages appear as channel notifications (validated in Section 11)
- ✅ README.md is complete
- ✅ Quality gates pass

**Submission checklist**:
- [x] E2E inbound message test passes
- [ ] Final README marketplace copy review
- [x] All commits pushed to PR
- [ ] PR merged to main
- [ ] Tag release: `git tag v1.0.0 && git push origin v1.0.0`
- [ ] Submit to marketplace

### 2. Investigate `--plugin-dir` MCP server behavior

- Reproduce with a minimal plugin fixture to confirm scope of the behavior
- Verify whether this is expected Claude Code behavior vs. a plugin layout/config issue
- Document the exact dev workflow in plugin README (root/project `.mcp.json` requirement)
- Confirm expected behavior for marketplace-installed plugins (whether packaged `.mcp.json` is registered automatically)

### 3. Final PR polish before merge

- Ensure PR description references the new E2E evidence in this handoff
- Confirm no additional plugin UX/docs tweaks are needed
- Merge PR #48 after review

### 4. Post-merge release + submission

- Create tag/release
- Submit plugin package and metadata
- Verify marketplace listing once approved

---

## 8. Reference Links

### PR & Issue
- **PR #48**: https://github.com/viche-ai/viche/pull/48
- **Issue #44**: https://github.com/viche-ai/viche/issues/44

### Claude Code Documentation
- **Plugin docs**: https://code.claude.com/docs/en/plugins
- **Plugin reference**: https://code.claude.com/docs/en/plugins-reference
- **Channels reference**: https://code.claude.com/docs/en/channels-reference
- **Channels overview**: https://code.claude.com/docs/en/channels

### Viche
- **Repository**: https://github.com/viche-ai/viche
- **Spec**: https://github.com/viche-ai/viche/blob/main/SPEC.md

---

## 9. Session Context

**What was asked**: Create a comprehensive session handoff document capturing everything done, what's working, what's not, and exactly what to do next.

**What was delivered**: This document (updated with E2E validation) now covering 11 sections:
1. Summary of goals and status
2. Detailed breakdown of all work done (plugin files, fixes, commits)
3. What's working (tools, quality gates, PR)
4. What's NOT working (`--plugin-dir` MCP registration behavior still unresolved)
5. Git state (branch, commits, PR)
6. Key learnings about Claude Code plugin system
7. Next steps in priority order (marketplace submission path)
8. Reference links
9. Session context (this section)
10. Quick start for remaining release work
11. E2E test results evidence

**Key takeaway**: The plugin is now validated end-to-end for inbound messaging. The next milestone is operational: PR merge, release tagging, and marketplace submission.

---

## 10. Quick Start (Next Session)

**To pick up where we left off**:

```bash
# 1. Verify branch status
git status

# 2. Open/update PR #48 as needed
gh pr view 48

# 3. Merge once approved
gh pr merge 48 --squash

# 4. Tag and push release
git tag v1.0.0
git push origin v1.0.0
```

**Then**: submit to marketplace using the links in Section 7.

---

## 11. Real Claude Code E2E Test Results (April 3 Session 2)

This section replaces the earlier standalone `bun run` validation with a **real Claude Code channel E2E run**.

### Test setup used

1. Temporarily updated root `.mcp.json` to define server `viche` pointing to:
   - `./channel/claude-code-plugin-viche/viche-server.ts`
   - `VICHE_REGISTRY_URL=http://localhost:4000`
2. Launched Claude Code:
   ```bash
   claude --dangerously-load-development-channels server:viche
   ```
3. Confirmed channel listener banner:
   - `Listening for channel messages from: server:viche`

### Registration and socket proof (Phoenix logs)

Observed in Phoenix during startup:

```text
[info] POST /registry/register
Parameters: %{"capabilities" => ["coding", "refactoring", "testing"], "description" => "Claude Code AI coding assistant", "name" => "claude-code"}
[info] AgentServer started for 44cb3e7d-2998-4b39-aff3-158ef2a14934
[info] Agent 44cb3e7d-2998-4b39-aff3-158ef2a14934 registered (name: "claude-code", capabilities: ["coding", "refactoring", "testing"], registries: ["global"])
[info] CONNECTED TO VicheWeb.AgentSocket
[info] Agent 44cb3e7d-2998-4b39-aff3-158ef2a14934 WebSocket connected
[info] JOINED agent:44cb3e7d-2998-4b39-aff3-158ef2a14934 in 146µs
```

### Inbound message test (HTTP → Claude channel)

Sent test message:

```bash
curl -s -X POST 'http://localhost:4000/messages/44cb3e7d-2998-4b39-aff3-158ef2a14934' \
  -H 'Content-Type: application/json' \
  -d '{"from":"e2e-tester","body":"This is a real E2E test message. If you see this, inbound messages work!","type":"task"}'
```

Claude Code TUI showed:

```text
← viche: [Task from e2e-tester] This is a real E2E test message. If …

⏺ viche - viche_reply (MCP)(to: "e2e-tester", body: "Inbound message confirmed received. E2E test successful!")

⏺ viche - viche_discover (MCP)(capability: "*")
```

### Reply/discovery proof in Phoenix

```text
[debug] HANDLED send_message INCOMING ON agent:44cb3e7d-... (VicheWeb.AgentChannel) in 7µs
  Parameters: %{"body" => "Inbound message confirmed received. E2E test successful!", "to" => "e2e-tester", "type" => "result"}
[debug] HANDLED discover INCOMING ON agent:44cb3e7d-... (VicheWeb.AgentChannel) in 28µs
  Parameters: %{"capability" => "*"}
```

### Confirmed behaviors

1. ✅ Claude Code receives inbound Viche tasks via channel (`← viche: [Task from ...] ...`)
2. ✅ Claude Code can autonomously act on inbound messages (issued `viche_reply`)
3. ✅ Claude Code can chain discovery behavior after receipt (`viche_discover`)
4. ✅ End-to-end loop validated with real Claude runtime, not standalone server simulation

### `--plugin-dir` limitation discovered during E2E

- Running with plugin dir only:
  ```bash
  claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche
  ```
  produced:
  - `server:viche · no MCP server configured with that name`

- Conclusion from this session:
  - `--plugin-dir` does **not** register MCP servers from plugin `.mcp.json` for this dev setup
  - Root/project `.mcp.json` must define `viche` for channel loading to work
  - If both root and plugin define `viche`, root definition wins

**Implication**: Development workflow must currently rely on root/project MCP config for server registration. Marketplace-installed behavior may differ and should be verified separately.

---

**End of handoff document**
