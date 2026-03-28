---
description: Inspect your product repository and generate a project-specific AGENTS.md
---

# /setup-repo

**Your ONLY job is to WRITE the file `AGENTS.md` at the Pantheon workspace root.**

You must:
1. READ the product repository in the current worktree to understand its stack
2. WRITE one file: the AGENTS.md at the workspace root (the `PANTHEON_ROOT` environment variable points there, or navigate two directories up from the worktree: `../../AGENTS.md`)

## Hard Rules

- **Do NOT** run any install, build, or test commands (`npm install`, `mix deps.get`, `pip install`, `cargo build`, etc.)
- **Do NOT** modify any files in the product repository
- **Do NOT** create or modify any files other than AGENTS.md
- **Do NOT** run the project's dev server, database migrations, or asset builds
- You are a READER and a WRITER of one file. Nothing else.

## Step 1: Identify the Stack

Read configuration files (do NOT execute anything):

- `package.json`, `deno.json`, `tsconfig.json` → Node.js / Deno / TypeScript
- `Cargo.toml` → Rust
- `go.mod` → Go
- `pyproject.toml`, `setup.py`, `requirements.txt` → Python
- `mix.exs` → Elixir
- `Gemfile` → Ruby
- `pom.xml`, `build.gradle` → Java
- `Makefile`, `Justfile` → Build system
- `.github/workflows/`, `.gitlab-ci.yml`, `.circleci/` → CI/CD

From these files, extract:
- Language(s) and framework(s)
- Test commands and test runner
- Lint and format commands
- Build / validation commands
- Package manager

## Step 2: Map the Structure

Read directory listing and key files:
- Top-level directories and their purposes
- Entry points (main files, route files, server files)
- Test directories and test file naming patterns
- Configuration files

## Step 3: Extract Conventions

Read (not execute) a few source files:
- 3-5 source files for import patterns, naming, structure
- 3-5 test files for test framework usage and patterns
- Linter/formatter configs (`.eslintrc`, `.prettierrc`, `rustfmt.toml`, `.formatter.exs`, etc.)
- README.md, CONTRIBUTING.md for existing conventions
- Recent git log for commit message patterns: `git log --oneline -20`

## Step 4: WRITE AGENTS.md (THIS IS YOUR PRIMARY DELIVERABLE)

Write the file to the workspace root. Use the `PANTHEON_ROOT` environment variable if available:
- If `$PANTHEON_ROOT` is set: write to `$PANTHEON_ROOT/AGENTS.md`
- Otherwise: write to `../../AGENTS.md` (relative to worktree in `worktrees/main/`)

You MUST include ALL of the following sections. Do not skip any.

```
# AGENTS.md

Instructions for AI agents working in this repository.

## Agent Pantheon

This workspace uses a multi-agent system coordinated by **Zeus** (the master orchestrator):

### Primary Agents

| Agent | Role | When Used |
|-------|------|-----------|
| **Zeus** | Master Orchestrator | Default agent. Routes work to specialists |
| **Prometheus** | Strategic Planner | Complex planning, requirements gathering |
| **Vulkanus** | TDD Implementer | Code changes, bug fixes, validation |
| **Mnemosyne** | System Cartographer | Research, documentation |
| **Oracle** | Architecture Advisor | Hard debugging, design decisions |
| **Argus** | Adversarial Reviewer | Pre-landing quality gate |

### Utility Agents

| Agent | Role |
|-------|------|
| **Explore** | Contextual grep — "Where is X?" |
| **Codebase Locator** | Find files and directories |
| **Codebase Analyzer** | Understand how code works |
| **Codebase Pattern Finder** | Find similar implementations |
| **Librarian** | External library docs |
| **Frontend Engineer** | UI/UX implementation |
| **Document Writer** | Technical documentation |
| **Translator** | Translation and i18n |
| **Thoughts Locator** | Find research documents |
| **Thoughts Analyzer** | Analyze research insights |

### Hunter Agents (dispatched by Argus)

| Agent | Role |
|-------|------|
| **Hunter Silent Failure** | Finds swallowed errors |
| **Hunter Type Design** | Finds type invariant violations |
| **Hunter Security** | Finds security vulnerabilities |
| **Hunter Code Review** | Finds convention violations |
| **Hunter Simplifier** | Simplifies code with proof |
| **Hunter Comments** | Audits comment accuracy |
| **Hunter Test Coverage** | Fills test coverage gaps |

---

## Repository Structure

[WRITE: Directory tree with descriptions of each directory's purpose]

## Build/Lint/Test Commands

### Validation (Run Before Committing)
[WRITE: The primary validation command — what agents should run before committing]

### Testing
[WRITE: All test commands with examples — run all, single file, with filter, etc.]

### Linting & Formatting
[WRITE: Lint, format, type-check commands]

### Development
[WRITE: Dev server commands if applicable]

## Code Style Guidelines

### Formatting
[WRITE: tabs/spaces, semicolons, quotes, line width — from formatter config]

### Imports
[WRITE: Import patterns with real examples from the codebase]

### Naming Conventions
[WRITE: File naming, variable naming, type naming patterns]

### Error Handling
[WRITE: Error handling patterns observed in the codebase]

## Testing
[WRITE: Test framework, test file naming, example test from real tests in the repo]

## Git Conventions

### Branch Naming
[WRITE: Pattern from git history or CONTRIBUTING.md]

### Commit Messages
[WRITE: Convention from git history]

## Architecture Quick Reference

### Key Files
[WRITE: Important entry points and their purposes]

## Critical Rules

1. Ask for clarification rather than making assumptions
2. Make smallest reasonable changes — don't refactor unrelated code
3. All changes need tests
[WRITE: Add project-specific rules discovered from the codebase]
```

## Step 5: Self-Verify

After writing AGENTS.md:
1. Read it back and confirm ALL sections above are present
2. Confirm it contains real commands (not placeholders like "TBD")
3. Confirm file paths referenced in the document actually exist in the repo
4. Report: "AGENTS.md written successfully with [N] sections covering [stack description]"

If any section is missing, go back and add it before finishing.
