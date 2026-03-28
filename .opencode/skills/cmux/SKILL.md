---
name: cmux
description: >
  Terminal multiplexer control for the launchclaw workspace. USE THIS skill
  when you need to read Phoenix server logs, run mix commands in a separate
  pane, restart the server, or manage the cmux workspace surfaces set up by
  `pt`. Covers terminal interaction only — for browser automation load the
  cmux-browser skill instead.
---

# cmux — Terminal Control Skill

## Session Context

When `pt` starts with cmux available it exports three environment variables
into the opencode process:

| Variable | Surface | Purpose |
|---|---|---|
| `$CMUX_OPENCODE_SURFACE` | `pane:<n>` | This OpenCode terminal |
| `$CMUX_SERVER_SURFACE` | `pane:<n>` | Phoenix server (`iex -S mix phx.server`) |
| `$CMUX_BROWSER_SURFACE` | `browser:<n>` | Embedded browser |

### Workspace layout

```
┌──────────────────┬──────────────────┐
│                  │ Phoenix Server   │
│   OpenCode       │ $CMUX_SERVER_SURFACE │
│   (you are here) ├──────────────────┤
│                  │ Browser          │
│                  │ $CMUX_BROWSER_SURFACE │
└──────────────────┴──────────────────┘
```

Check if surfaces are set:

```bash
echo "OC:  $CMUX_OPENCODE_SURFACE"
echo "SRV: $CMUX_SERVER_SURFACE"
echo "BR:  $CMUX_BROWSER_SURFACE"
```

If the variables are empty, cmux was not running when `pt` started. Use
fallback discovery (see `references/workspace-layout.md`).

---

## Capabilities Discovery

```bash
cmux capabilities
```

Prints every command and flag the installed version supports. Run this first
if a command returns an unexpected error.

---

## Fast Start — Common Patterns

### Read the Phoenix server log (last 50 lines)

```bash
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 50
```

### Send a command to the server pane

```bash
cmux send --surface "$CMUX_SERVER_SURFACE" "mix ecto.migrate\n"
```

### Restart the Phoenix server

```bash
# Ctrl-C to stop
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c
sleep 1
# Start again
cmux send --surface "$CMUX_SERVER_SURFACE" "iex -S mix phx.server\n"
```

### Run a mix task without leaving opencode

```bash
cmux send --surface "$CMUX_SERVER_SURFACE" "mix test\n"
# Wait a moment, then read results
sleep 5
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 80
```

### Send Ctrl-C + new command atomically

```bash
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c
cmux send --surface "$CMUX_SERVER_SURFACE" "iex -S mix phx.server\n"
```

---

## When to Use cmux vs Other Tools

| Situation | Tool |
|---|---|
| Read Phoenix server output | `cmux read-screen` on `$CMUX_SERVER_SURFACE` |
| Run `mix` commands | `cmux send` to `$CMUX_SERVER_SURFACE` |
| Restart the server | `send-key ctrl-c` then `send iex -S mix phx.server` |
| Open/navigate browser | Load `cmux-browser` skill |
| Take a page screenshot | Load `cmux-browser` skill |
| Read/write Elixir files | Standard file tools (Read/Write/Edit) |
| Run git commands | Bash tool directly |

---

## Reference Documents

- `references/workspace-layout.md` — layout details, env vars, fallback discovery
- `references/terminal-interaction.md` — read-screen, send, send-key reference + Phoenix examples
- `references/panes-and-surfaces.md` — splits, focus, close, notifications
