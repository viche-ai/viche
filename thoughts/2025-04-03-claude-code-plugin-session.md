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
- ✅ PR #48 open with 2 commits
- ⚠️ **2 unpushed commits** on local branch (notification fix + env var fallback fix)
- ❌ **E2E inbound message validation NOT completed** — core blocker for marketplace submission

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

**Commit**: `5659336` (unpushed)

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

**Commit**: `8b5f600` (unpushed)

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
- **Quality gates pass**:
  - 397 tests passing
  - 0 Credo issues
  - 0 Dialyzer warnings
- **PR #48 is open** with 2 commits (first commit pushed, 2 follow-up commits unpushed)

---

## 4. What's NOT Working Yet ❌

### Inbound Message Delivery (CRITICAL BLOCKER)

**The core issue**: Claude Code agents can discover and send messages, but **NEVER receive inbound messages from other agents**.

Three layers of fixes were applied but **E2E validation of inbound messages was NOT completed**:

1. ✅ **Channel flag** — `--dangerously-load-development-channels server:viche` is now documented and confirmed to register the channel listener
2. ✅ **Notification format** — fixed to match Claude Code spec (`content` + `meta` only, no `channel` field)
3. ✅ **Env var fallback** — `||` instead of `??` to handle empty userConfig values

**The remaining blocker for E2E testing**: When the user's shell has `VICHE_REGISTRY_URL=https://viche.ai` set globally (for the OpenCode plugin), and the plugin's `.mcp.json` maps `"VICHE_REGISTRY_URL": "${user_config.registry_url}"`, there's an interaction:

- If userConfig is set → works correctly
- If userConfig is NOT set → Claude Code may not override the parent env var, so the MCP server connects to prod instead of localhost
- The `||` fix helps when the env var is explicitly set to empty string, but may not help when it's inherited from the parent shell

**This needs validation**: Start Claude Code with the plugin, verify the agent registers on localhost (check Phoenix server logs for `POST /registry/register`), then send a message to the agent and verify the `<channel>` tag appears in the Claude Code session.

**E2E test steps** (NOT YET COMPLETED):

1. Start Phoenix server: `iex -S mix phx.server`
2. Verify health: `curl http://localhost:4000/health` → `ok`
3. Start Claude Code: `claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche`
4. Check Phoenix logs for `POST /registry/register` — if missing, the env var issue persists
5. If registered, find agent ID: `curl http://localhost:4000/registry/discover?capability=*`
6. Send message: `curl -X POST http://localhost:4000/messages/<agent-id> -H "Content-Type: application/json" -d '{"from":"test","body":"hello","type":"task"}'`
7. Verify `<channel source="viche">` tag appears in Claude Code session

---

## 5. Git State

**Branch**: `feature/claude-code-plugin`

**Remote**: `origin/feature/claude-code-plugin` at commit `5d5b34b` (first commit only)

**Unpushed commits** (2):
- `5659336` — fix: align Claude channel notifications with spec
- `8b5f600` — fix: use falsy env fallbacks in Claude plugin config

**PR**: https://github.com/viche-ai/viche/pull/48
- Shows 2 commits in PR (GitHub is showing the first 2 commits from the branch)
- The PR description mentions E2E testing was done, but the unpushed commits suggest further fixes were needed

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

### 1. Push unpushed commits ⚠️ URGENT

```bash
git push origin feature/claude-code-plugin
```

This will update PR #48 with the notification fix and env var fallback fix.

### 2. E2E validate inbound messages 🔴 CRITICAL BLOCKER

**Goal**: Verify that messages sent to the Claude Code agent appear as `<channel>` tags in the session.

**Steps**:

1. **Start Phoenix server**:
   ```bash
   iex -S mix phx.server
   ```

2. **Verify health**:
   ```bash
   curl http://localhost:4000/health
   # Expected: ok
   ```

3. **Start Claude Code with plugin**:
   ```bash
   claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche
   ```

4. **Check Phoenix logs for registration**:
   - Look for `POST /registry/register` in the Phoenix server logs
   - If missing → env var issue persists (see step 3 below)
   - If present → note the agent ID from the response

5. **Find agent ID** (if not in logs):
   ```bash
   curl http://localhost:4000/registry/discover?capability=*
   # Look for the agent with capabilities matching your config
   ```

6. **Send a test message**:
   ```bash
   curl -X POST http://localhost:4000/messages/<agent-id> \
     -H "Content-Type: application/json" \
     -d '{"from":"test-sender","body":"Hello from curl","type":"task"}'
   ```

7. **Verify in Claude Code session**:
   - Check for `<channel source="viche">` tag with the message
   - Expected format: `<channel source="viche" message_id="msg-..." from="test-sender" type="task">[Task from test-sender] Hello from curl</channel>`

**If step 4 fails** (no registration in Phoenix logs):
- The MCP server is connecting to the wrong registry URL (likely prod instead of localhost)
- Proceed to step 3 below

### 3. Fix env var inheritance issue (if E2E fails)

**If the agent doesn't register on localhost**, the issue is env var inheritance from the parent shell.

**Option A**: Remove env var mappings from `.mcp.json` and read `CLAUDE_PLUGIN_OPTION_*` directly

Claude Code auto-exports all userConfig values as `CLAUDE_PLUGIN_OPTION_<KEY>` env vars. The MCP server can read these directly:

```typescript
// viche-server.ts
const REGISTRY_URL =
  process.env.CLAUDE_PLUGIN_OPTION_REGISTRY_URL ||
  process.env.VICHE_REGISTRY_URL ||
  "http://localhost:4000";
```

This bypasses the `.mcp.json` mapping and avoids the inheritance issue.

**Option B**: Document the workaround

Add to README.md:
```markdown
### Known issue: env var inheritance

If you have `VICHE_REGISTRY_URL` set in your shell (for other plugins), the Claude Code plugin may inherit it instead of using the default `http://localhost:4000`.

**Workaround**: Unset the env var before launching Claude Code:
```bash
unset VICHE_REGISTRY_URL
claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche
```
```

### 4. Submit to marketplace (once inbound messages work)

**Submission URL**: https://claude.ai/settings/plugins/submit or https://platform.claude.com/plugins/submit

**Prerequisites**:
- ✅ Plugin loads without errors
- ✅ All tools work
- ✅ Inbound messages appear as `<channel>` tags (MUST VERIFY)
- ✅ README.md is complete
- ✅ Quality gates pass

**Submission checklist**:
- [ ] E2E inbound message test passes
- [ ] README.md updated with marketplace install instructions
- [ ] All commits pushed to PR
- [ ] PR merged to main
- [ ] Tag release: `git tag v1.0.0 && git push origin v1.0.0`
- [ ] Submit to marketplace

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

**What was delivered**: This document with 9 sections covering:
1. Summary of goals and status
2. Detailed breakdown of all work done (plugin files, fixes, commits)
3. What's working (tools, quality gates, PR)
4. What's NOT working (inbound message E2E validation blocker)
5. Git state (branch, commits, PR)
6. Key learnings about Claude Code plugin system
7. Next steps in priority order (push commits, E2E test, fix env vars, submit)
8. Reference links
9. Session context (this section)

**Key takeaway**: The plugin is 95% complete. The only blocker for marketplace submission is **E2E validation of inbound messages**. Once that's verified (or the env var issue is fixed), the plugin is ready to ship.

---

## 10. Quick Start (Next Session)

**To pick up where we left off**:

```bash
# 1. Push unpushed commits
git push origin feature/claude-code-plugin

# 2. Start Phoenix server
iex -S mix phx.server

# 3. In another terminal, start Claude Code with plugin
claude --plugin-dir ./channel/claude-code-plugin-viche --dangerously-load-development-channels server:viche

# 4. Check Phoenix logs for POST /registry/register
# If missing → env var issue (see section 7, step 3)
# If present → proceed to step 5

# 5. Get agent ID
curl http://localhost:4000/registry/discover?capability=*

# 6. Send test message
curl -X POST http://localhost:4000/messages/<agent-id> \
  -H "Content-Type: application/json" \
  -d '{"from":"test","body":"hello","type":"task"}'

# 7. Check Claude Code session for <channel> tag
# Expected: <channel source="viche" ...>[Task from test] hello</channel>
```

**If step 4 fails**: The env var inheritance issue is confirmed. Apply fix from section 7, step 3.

**If step 7 succeeds**: Inbound messages work! Proceed to marketplace submission (section 7, step 4).

---

**End of handoff document**
