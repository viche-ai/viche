---
name: cmux-browser
description: >
  Browser automation for the launchclaw workspace via cmux. USE THIS skill
  when you need to navigate to a URL, take a page screenshot, inspect the
  DOM, click elements, fill forms, evaluate JavaScript, or read console
  errors in the embedded browser. Default URL is http://localhost:4000.
  Requires cmux to be running with $CMUX_BROWSER_SURFACE set.
---

# cmux-browser — Browser Automation Skill

## Session Context

The embedded browser surface is available after `pt` starts with cmux:

```bash
echo "$CMUX_BROWSER_SURFACE"   # e.g. browser:1
```

If empty, open a browser surface manually:

```bash
json=$(cmux --json browser open "about:blank")
export CMUX_BROWSER_SURFACE=$(echo "$json" | grep -o '"browser_ref"[[:space:]]*:[[:space:]]*"browser:[0-9]*"' \
  | grep -o 'browser:[0-9]*' | head -n 1)
```

---

## Core Workflow

The standard agent loop for any browser task:

```
navigate → wait → snapshot → act → wait → snapshot → verify
```

### 1. Navigate

```bash
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "http://localhost:4000"
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "http://localhost:4000/users/new"
```

### 2. Wait for content

```bash
# Wait for a CSS selector to appear (polls until timeout)
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector "h1"
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector ".flash-error" --timeout 5000

# Wait for text to appear on the page
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --text "Welcome"
```

### 3. Snapshot (accessibility tree)

```bash
# Preferred — returns the a11y tree (fast, token-efficient)
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE"

# With full verbose a11y output
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE" --verbose
```

Read the snapshot to find element refs (`uid`) for interaction.

### 4. Screenshot

```bash
# Attach screenshot inline (for analysis)
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE"

# Save to file
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE" --output /tmp/page.png
```

### 5. Click

```bash
# Click by CSS selector
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector "button[type=submit]"
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector "a[href='/login']"

# Click by element uid from snapshot
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --uid "<uid-from-snapshot>"

# Double click
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector ".item" --double
```

### 6. Fill forms

```bash
# Fill an input by selector
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "input[name=email]" --value "test@example.com"
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "input[name=password]" --value "secret"

# Fill by uid
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --uid "<uid>" --value "some text"

# Select a dropdown option
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "select[name=role]" --value "admin"
```

### 7. Evaluate JavaScript

```bash
# Returns JSON-serializable result
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "document.title"
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "document.querySelectorAll('li').length"
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "window.location.href"

# Execute async JS
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "await fetch('/api/health').then(r => r.status)"
```

### 8. Console output

```bash
# List all console messages since last navigation
cmux browser console --surface "$CMUX_BROWSER_SURFACE"

# Filter by type
cmux browser console --surface "$CMUX_BROWSER_SURFACE" --type error
cmux browser console --surface "$CMUX_BROWSER_SURFACE" --type warn
```

### 9. Network requests

```bash
# List network requests
cmux browser network --surface "$CMUX_BROWSER_SURFACE"

# Filter by resource type
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --type fetch
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --type xhr
```

---

## Stable Agent Loop

For reliable UI verification, always follow this sequence:

```bash
# 1. Navigate
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "http://localhost:4000"

# 2. Wait for the page to be meaningful
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector "main"

# 3. Take snapshot to understand structure
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE"

# 4. Act on elements found in snapshot
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector "button.sign-in"

# 5. Wait for result
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --text "Welcome back"

# 6. Verify
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE"
```

Never click blindly — always snapshot first to confirm the element exists.

---

## WKWebView Limitations

The embedded browser uses macOS WKWebView. Be aware:

- **No cross-origin XHR** to external domains by default
- **No browser extensions** (no ad blockers, etc.)
- **WebSockets work** — Phoenix LiveView connections function normally
- **localStorage/sessionStorage work** normally
- **Service workers** may have limitations
- **PDF downloads** open in the viewer rather than downloading
- Some **third-party login popups** may not render correctly

For Phoenix LiveView apps these limitations are not a practical concern.

---

## Reference Document

- `references/commands.md` — full command reference with all flags
