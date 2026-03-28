---
description: Intelligently merge upstream Pantheon updates while preserving your customizations
---

# /update

You are merging upstream Pantheon updates into this workspace while preserving user customizations.

## Context

The user ran `make update` which:
1. Added `pantheon-upstream` remote pointing to `github.com/ihorkatkov/pantheon`
2. Fetched the latest `pantheon-upstream/main`
3. Detected a version mismatch between local and upstream `.pantheon-version`
4. Launched you to perform the intelligent merge

## What You Do

### Step 1: Understand What Changed

Compare local vs upstream:
```bash
git diff HEAD...pantheon-upstream/main --stat
git diff HEAD...pantheon-upstream/main
```

Categorize changes:
- **Agent updates**: `.opencode/agents/*.md`
- **Command updates**: `.opencode/commands/*.md`
- **Skill updates**: `.opencode/skills/**`
- **CLI updates**: `pt`, `setup-worktree`, `Makefile`
- **Config updates**: `.opencode/opencode.jsonc`
- **Doc updates**: `README.md`, `docs/`

### Step 2: Identify User Customizations

Check which files the user has modified:
```bash
# Files user has changed since initial clone/last update
git log --all --diff-filter=M --name-only --pretty=format: -- .opencode/ pt setup-worktree Makefile | sort -u
```

Read current versions of modified files to understand user customizations.

### Step 3: Merge Strategy

For each changed file:

**Unmodified by user** → Apply upstream change directly (overwrite with upstream version)

**Modified by user** → Smart merge:
- If upstream changed mythology/role sections and user changed project-specific sections → merge both
- If both changed the same section → present both versions to the user and ask which to keep
- If user added new content that upstream doesn't touch → preserve user additions

**New upstream files** → Add directly

**Deleted upstream files** → Remove (notify user if they had modifications)

### Step 4: Apply Changes
- Apply non-conflicting changes
- Present conflicts for user resolution
- Update `.pantheon-version` to the upstream version

### Step 5: Verify
- Ensure all agent files are valid markdown with frontmatter
- Ensure no merge artifacts (`<<<<<<<`, `=======`, `>>>>>>>`)
- Report: what was updated, what was preserved, what needs user attention

## Critical Rules

- NEVER overwrite the user's AGENTS.md — that's project-specific content
- NEVER overwrite user-created custom agents (files that don't exist in upstream)
- NEVER overwrite user-created custom commands or skills
- ALWAYS preserve user modifications to operational sections of agents
- Prefer upstream for structural/role definition updates
- Prefer user for project-specific customizations
- Update `.pantheon-version` only after all changes are applied
