# Session Handoff: Claude Code Plugin Install + Channel Fix

**Date**: April 5, 2026  
**Branch**: `docs/readme-supported-agents`  
**Base**: `main` (PR #48 merged)

---

## 1. Summary

This session focused on:

1. **Updating the README** with a clear "Supported Agents" section and Claude Code plugin install instructions
2. **Creating a self-hosted marketplace** (`.claude-plugin/marketplace.json`) for plugin distribution
3. **E2E testing the plugin install flow** — uncovered and fixed multiple issues
4. **Discovering the correct channel activation syntax** for installed plugins

**Current Status**:
- ✅ README updated with Supported Agents table
- ✅ marketplace.json moved to `.claude-plugin/marketplace.json` (correct location)
- ✅ plugin.json fixed — added required `type` and `title` to all `userConfig` fields
- ✅ `claude plugin marketplace add` works
- ✅ `claude plugin install viche@viche` works
- ⚠️ marketplace.json `ref` is temporarily set to `"docs/readme-supported-agents"` (needs to be `"main"` before merge)
- ❌ Channel activation NOT yet tested with correct `plugin:viche@viche` syntax
- ❌ README install instructions still use `--dangerously-load-development-channels server:viche` (wrong)

---

## 2. What Was Done

### README Updated

**File**: `README.md`

Replaced "Real-time Messaging (Plugins)" section (lines 73-81) with a "Supported Agents" section containing a markdown table:

| Agent | Install | Docs |
|-------|---------|------|
| Claude Code | marketplace add + plugin install | Plugin README link |
| OpenClaw | npm install | Plugin README link |
| OpenCode | See plugin setup | Plugin README link |

Also updated the Resources section to match.

**Commit**: `docs: update README with supported agents and Claude Code plugin install`

### Marketplace Location Fix

**Problem**: `marketplace.json` was at repo root. Claude Code looks for it at `.claude-plugin/marketplace.json`.

**Error**: `Failed to add marketplace: Marketplace file not found at .../.claude-plugin/marketplace.json`

**Fix**: `git mv marketplace.json .claude-plugin/marketplace.json`

**Commit**: `fix: move marketplace.json to .claude-plugin/ for Claude Code discovery`

### Plugin Manifest Fix

**Problem**: `plugin.json` `userConfig` fields were missing required `type` and `title` properties.

**Error**: `Plugin has an invalid manifest file... userConfig.registry_url.type: Invalid option: expected one of "string"|"number"|"boolean"|"directory"|"file", userConfig.registry_url.title: Invalid input: expected string, received undefined`

**Fix**: Added `"type": "string"` and `"title": "..."` to all 5 userConfig fields in `channel/claude-code-plugin-viche/.claude-plugin/plugin.json`.

**Commit**: `fix: add required type and title fields to plugin manifest`

### Temporary Ref Change

**Problem**: `marketplace.json` has `"ref": "main"` but the fixes aren't on main yet. So `claude plugin install` was still pulling the unfixed `plugin.json` from main.

**Fix**: Temporarily changed `ref` to `"docs/readme-supported-agents"` for testing.

**Commit**: `chore: temp branch ref for testing`

⚠️ **This MUST be changed back to `"main"` before merging the PR.**

---

## 3. What's Working ✅

- **`claude plugin marketplace add viche-ai/viche@docs/readme-supported-agents`** → ✔ Successfully added marketplace
- **`claude plugin install viche@viche`** → ✔ Successfully installed plugin (scope: user)
- Plugin appears in `~/.claude/settings.json` → `"enabledPlugins": { "viche@viche": true }`
- Plugin files installed to `~/.claude/plugins/cache/viche/viche/1.0.0/`
- Plugin data (node_modules) at `~/.claude/plugins/data/viche-viche/`
- SessionStart hook ran `bun install` successfully

---

## 4. What's NOT Working Yet ❌

### Channel Activation (CRITICAL — Not Yet Tested)

We discovered the correct syntax but haven't tested it yet:

**Wrong** (what we were using):
```bash
claude --dangerously-load-development-channels server:viche
```
This looks for a server named "viche" in project/user `.mcp.json` files — NOT in installed plugins.

**Correct** (from Claude Code docs):
```bash
claude --dangerously-load-development-channels plugin:viche@viche
```
This loads the channel from the installed plugin `viche@viche`.

**Source**: https://code.claude.com/docs/en/channels-reference#test-during-the-research-preview

> ```bash
> # Testing a plugin you're developing
> claude --dangerously-load-development-channels plugin:yourplugin@yourmarketplace
> 
> # Testing a bare .mcp.json server (no plugin wrapper yet)
> claude --dangerously-load-development-channels server:webhook
> ```

### README Install Instructions Need Updating

The current README still shows:
```bash
claude --dangerously-load-development-channels server:viche
```

Needs to be updated to:
```bash
claude --dangerously-load-development-channels plugin:viche@viche
```

This applies to:
- `channel/claude-code-plugin-viche/README.md` — Local development section
- `README.md` — if we add channel usage instructions

---

## 5. Key Discoveries

### 1. Marketplace file location
Claude Code expects `.claude-plugin/marketplace.json`, NOT `marketplace.json` at repo root.

### 2. Plugin manifest requires type + title
Every `userConfig` field MUST have:
- `"type"`: one of `"string"|"number"|"boolean"|"directory"|"file"`
- `"title"`: human-readable label (string)

### 3. Channel flag syntax differs for plugins vs bare MCP servers
- `server:name` → looks in `.mcp.json` files (project/user level)
- `plugin:name@marketplace` → loads from installed plugin

### 4. Plugin MCP servers auto-start
From docs: "Plugin MCP servers start automatically when the plugin is enabled." The `.mcp.json` inside the plugin IS respected when properly installed via `claude plugin install`.

### 5. Custom channels need allowlist or dev flag
From docs: "A channel published to your own marketplace still needs `--dangerously-load-development-channels` to run, since it isn't on the approved allowlist."

To get on the allowlist: submit to official marketplace at https://claude.ai/settings/plugins/submit or https://platform.claude.com/plugins/submit

### 6. Cache stale after marketplace updates
When re-adding a marketplace after changes, the plugin cache at `~/.claude/plugins/cache/` may be stale. Full cleanup:
```bash
claude plugin marketplace remove viche
rm -rf ~/.claude/plugins/marketplaces/viche
rm -rf ~/.claude/plugins/cache/temp_subdir_*
claude plugin marketplace add viche-ai/viche
claude plugin install viche@viche
```

---

## 6. Git State

**Branch**: `docs/readme-supported-agents`

**Commits on branch** (4, all pushed):
1. `docs: update README with supported agents and Claude Code plugin install`
2. `fix: move marketplace.json to .claude-plugin/ for Claude Code discovery`
3. `fix: add required type and title fields to plugin manifest`
4. `chore: temp branch ref for testing`

**No PR created yet** for this branch.

**Working tree**: clean (except `.claude/settings.local.json` and `.beads/` which are untracked/modified)

---

## 7. Next Steps (Priority Order)

### 1. Test channel with correct `plugin:viche@viche` syntax 🔴 CRITICAL

```bash
# 1. Start Phoenix server
iex -S mix phx.server

# 2. Launch Claude Code with correct flag
claude --dangerously-load-development-channels plugin:viche@viche

# 3. Expected: "Listening for channel messages from: plugin:viche@viche"
# 4. Expected: NO "no MCP server configured" error
# 5. Check Phoenix logs for POST /registry/register
# 6. Send test message and verify <channel> tag appears
```

### 2. Update README install instructions

Update `channel/claude-code-plugin-viche/README.md`:
- Change all `server:viche` references to `plugin:viche@viche`
- Update the install flow to: marketplace add → plugin install → launch with flag

### 3. Change marketplace.json ref back to "main"

**Before merging**: change `.claude-plugin/marketplace.json` `ref` from `"docs/readme-supported-agents"` back to `"main"`.

### 4. Create PR and merge

Create PR for `docs/readme-supported-agents` → `main` with all fixes.

### 5. Test from clean state

After merging to main:
```bash
claude plugin marketplace remove viche
rm -rf ~/.claude/plugins/marketplaces/viche
rm -rf ~/.claude/plugins/cache/viche
claude plugin marketplace add viche-ai/viche
claude plugin install viche@viche
claude --dangerously-load-development-channels plugin:viche@viche
```

### 6. Submit to official marketplace (optional)

Once E2E works with the plugin flag, submit to get on the approved allowlist so users don't need `--dangerously-load-development-channels`.

---

## 8. File Locations Reference

| File | Purpose |
|------|---------|
| `.claude-plugin/marketplace.json` | Self-hosted marketplace definition (at repo root) |
| `channel/claude-code-plugin-viche/.claude-plugin/plugin.json` | Plugin manifest |
| `channel/claude-code-plugin-viche/.mcp.json` | MCP server config (auto-loaded by plugin system) |
| `channel/claude-code-plugin-viche/viche-server.ts` | MCP server implementation |
| `channel/claude-code-plugin-viche/README.md` | Plugin documentation |
| `channel/claude-code-plugin-viche/skills/viche/SKILL.md` | Viche network skill |
| `channel/claude-code-plugin-viche/hooks/hooks.json` | SessionStart hook (bun install) |
| `channel/claude-code-plugin-viche/package.json` | Plugin dependencies |
| `thoughts/2025-04-03-claude-code-plugin-session.md` | Previous session handoff |

---

## 9. Claude Code Plugin Docs Reference

- **Channels reference**: https://code.claude.com/docs/en/channels-reference
- **Plugins**: https://code.claude.com/docs/en/plugins
- **Plugin reference**: https://code.claude.com/docs/en/plugins-reference
- **Plugin marketplaces**: https://code.claude.com/docs/en/plugin-marketplaces
- **MCP**: https://code.claude.com/docs/en/mcp
- **Channels overview**: https://code.claude.com/docs/en/channels

---

## 10. Quick Start (Next Session)

```bash
# 1. Switch to the branch
git checkout docs/readme-supported-agents

# 2. Start Phoenix server
iex -S mix phx.server

# 3. Test the channel with correct flag
claude --dangerously-load-development-channels plugin:viche@viche

# 4. If it works:
#    - Update README references from server:viche to plugin:viche@viche
#    - Change marketplace.json ref back to "main"
#    - Create PR
#    - Merge

# 5. If it doesn't work:
#    - Check /mcp in Claude Code for server status
#    - Check ~/.claude/debug/<session-id>.txt for stderr
#    - Review plugin loading in Claude Code docs
```

---

**End of handoff document**
