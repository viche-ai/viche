# cmux Workspace Layout

## How `pt` Creates the Context

When you run `pt [worktree]` and cmux is detected (`cmux ping` succeeds),
the script executes `setup_cmux_workspace` which:

1. **Identifies current pane** via `cmux --json identify` → stored as `CMUX_OPENCODE_SURFACE`
2. **Splits right** via `cmux --json new-split right` → becomes `CMUX_SERVER_SURFACE`
3. **Focuses the server pane**, splits down to create bottom-right placeholder, opens browser via `cmux --json browser open "about:blank"`, then moves browser to bottom-right pane → becomes `CMUX_BROWSER_SURFACE`
4. **Sends** `iex -S mix phx.server` to the server surface
5. **Exports** all three env vars into the opencode process environment
6. **Restores focus** to the opencode pane
7. **After 5 seconds** (background), navigates the browser to `http://localhost:4000`

## Layout Diagram

```
┌──────────────────────┬──────────────────────┐
│                      │ Phoenix Server        │
│   OpenCode           │ pane:<n>              │
│   (agent runs here)  │ mix phx.server output │
│                      ├──────────────────────┤
│                      │ Browser               │
│                      │ browser:<n>           │
│                      │ http://localhost:4000 │
└──────────────────────┴──────────────────────┘
```

## Environment Variables

| Variable | Format | Example | Notes |
|---|---|---|---|
| `CMUX_OPENCODE_SURFACE` | `pane:<id>` | `pane:1` | The pane where OpenCode runs |
| `CMUX_SERVER_SURFACE` | `pane:<id>` | `pane:2` | Phoenix server output |
| `CMUX_BROWSER_SURFACE` | `browser:<id>` | `browser:1` | Embedded browser; may be empty if browser open failed |

## Fallback Discovery

If env vars are empty (pt was run without cmux, or cmux started after pt):

```bash
# List all surfaces
cmux list-surfaces

# Identify which pane you're currently in
cmux --json identify

# Then set the variables manually for this session
export CMUX_SERVER_SURFACE="pane:2"
export CMUX_BROWSER_SURFACE="browser:1"
```

To find the server pane, look for the one running `iex -S mix phx.server`:

```bash
cmux read-screen --surface pane:2 --lines 5
# If it shows Phoenix boot output, that's the server pane
```

## Working Directory

All `pt`-managed worktrees live under:

```
/Users/ihorkatkov/Projects/launchclaw-workspace/worktrees/<name>/
```

The `main` worktree is the default. The Phoenix server is always started in
`$WORKTREE_PATH` (the worktree that was active when `pt` ran).
