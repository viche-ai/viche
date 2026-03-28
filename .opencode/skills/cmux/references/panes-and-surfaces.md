# cmux Panes and Surfaces Reference

## Surface Types

| Type | Ref format | Description |
|---|---|---|
| Terminal pane | `pane:<id>` | A shell/terminal split |
| Browser | `browser:<id>` | Embedded WKWebView browser pane |

Surfaces are referenced by their typed ref string everywhere in cmux commands
(`--surface`, `--pane`, `--browser` flags).

---

## Listing Surfaces

```bash
# List all open surfaces with their refs
cmux list-surfaces

# Identify current pane (returns JSON with pane_ref)
cmux --json identify
```

---

## Creating Splits

```bash
# Split the current pane, adding a new pane to the right
cmux --json new-split right

# Split downward (below current pane)
cmux --json new-split down

# Split left
cmux --json new-split left

# Split up
cmux --json new-split up
```

The `--json` flag makes cmux return JSON output, which contains the new
surface ref. Parse with grep:

```bash
json=$(cmux --json new-split right)
new_pane=$(echo "$json" | grep -o '"pane_ref"[[:space:]]*:[[:space:]]*"pane:[0-9]*"' \
  | grep -o 'pane:[0-9]*' | head -n 1)
```

---

## Focus Management

```bash
# Focus a specific pane by ref
cmux focus-pane --pane "$CMUX_SERVER_SURFACE"

# Return focus to opencode pane
cmux focus-pane --pane "$CMUX_OPENCODE_SURFACE"

# Focus by surface (generic)
cmux focus --surface "$CMUX_BROWSER_SURFACE"
```

---

## Closing Surfaces

```bash
# Close a pane
cmux close-surface --surface "$CMUX_SERVER_SURFACE"

# Close browser
cmux close-surface --surface "$CMUX_BROWSER_SURFACE"
```

> **Note**: Do not close `$CMUX_OPENCODE_SURFACE` — that is the pane you
> are running in.

---

## Notifications

Send a desktop notification (useful for long async tasks):

```bash
cmux notify "mix test finished"
cmux notify --title "Launchclaw" "Server restarted successfully"
```

---

## Checking cmux Availability

```bash
# Returns 0 if cmux daemon is running, non-zero otherwise
cmux ping

# Combine with shell conditional
if cmux ping &>/dev/null; then
  echo "cmux is available"
else
  echo "cmux not running"
fi
```

---

## JSON Output Mode

Many cmux commands accept `--json` to return machine-readable output instead
of human-formatted text. Always use `--json` when you need to extract a ref
from the output.

```bash
# Without --json: human output
cmux identify

# With --json: structured output for parsing
cmux --json identify
# {"pane_ref": "pane:1", "session": "...", ...}
```
